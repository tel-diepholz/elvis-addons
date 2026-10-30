#!/bin/sh
# Zusatzdaten für Planetiler (Wasserflächen, Natural Earth, Seenbeschriftung) selbst laden.
# Planetiler bricht beim eigenen Download schon bei einer langsamen Antwort ab; hier gibt es Wiederholungen,
# Fortsetzen abgebrochener Downloads und – bei Aktualisierungen – den Rückgriff auf die vorhandene Kopie.
# Geladen wird nur, wenn sich die Datei auf dem Server geändert hat (If-Modified-Since).
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }
. /data/addon/scripts/tools.sh

S=${SOURCES_DIR:-/data/sources}
if [ -z "${SKIP_TOOLS:-}" ]; then
  progress 1 "Werkzeuge installieren"
  install_tools
fi
mkdir -p "$S"

# Leerer Shapefile-Platzhalter (Polygon, ohne Einträge), falls die Wasserflächen nicht zu bekommen sind.
# Planetiler läuft damit durch; es fehlen nur Meeresflächen (Seen und Flüsse kommen aus den OSM-Daten).
empty_water() {
  d=$(mktemp -d)
  mkdir -p "$d/water-polygons-split-3857"
  # .shp/.shx-Kopf: Dateicode 9994 (BE), Länge 50 Worte (BE), Version 1000 (LE), Typ 5 = Polygon (LE), Bounding Box 0
  hdr='\000\000\047\012\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\062\350\003\000\000\005\000\000\000'
  for ext in shp shx; do
    # shellcheck disable=SC2059
    { printf "$hdr"; head -c 64 /dev/zero; } > "$d/water-polygons-split-3857/water_polygons.$ext"
  done
  # .dbf: dBase III, 0 Datensätze, ein Feld „x“ (N, Länge 1)
  { printf '\003\176\001\001\000\000\000\000\101\000\002\000'; head -c 20 /dev/zero
    printf 'x'; head -c 10 /dev/zero; printf 'N'; head -c 4 /dev/zero; printf '\001\000'; head -c 14 /dev/zero
    printf '\015\032'; } > "$d/water-polygons-split-3857/water_polygons.dbf"
  # Projektion (EPSG:3857), sonst lehnt Planetiler die Datei ab
  printf '%s' 'PROJCS["WGS 84 / Pseudo-Mercator",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]],PROJECTION["Mercator_1SP"],PARAMETER["central_meridian",0],PARAMETER["scale_factor",1],PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1,AUTHORITY["EPSG","9001"]],AXIS["X",EAST],AXIS["Y",NORTH],AUTHORITY["EPSG","3857"]]' > "$d/water-polygons-split-3857/water_polygons.prj"
  rm -f "$1"
  (cd "$d" && zip -qr "$1" water-polygons-split-3857)
  rm -rf "$d"
}

# Nicht zu bekommen: vorhandene Kopie, sonst Platzhalter, sonst Abbruch
unavailable() {
  if [ -s "$f" ]; then
    echo "WARNUNG: $label nicht erreichbar ($url), die vorhandene Kopie wird verwendet"
    progress "$to" "$label: vorhandene Kopie"
  elif [ -n "$fallback" ]; then
    echo "WARNUNG: $label nicht erreichbar ($url) – es wird ohne sie weitergemacht. Meeresflächen an Küsten fehlen bis zur nächsten erfolgreichen Aktualisierung; Binnenregionen sind nicht betroffen."
    "$fallback" "$f"
    touch "$f.placeholder"
    progress "$to" "$label nicht erreichbar – Platzhalter"
  else
    echo "FEHLER: $label konnte nicht geladen werden ($url). Internetverbindung des Docker-Hosts prüfen und den Job erneut starten – bereits geladene Teile werden fortgesetzt."
    exit 1
  fi
}

# Server-Abfrage: 3 Versuche mit je 10 s Wartezeit, danach wird nicht länger gewartet
PROBE="--retry 2 --retry-delay 1 --retry-all-errors --connect-timeout 10 --max-time 10"

# fetch <url> <datei> <bezeichnung> <von %> <bis %> [platzhalter-funktion]
fetch() {
  url=$1 f="$S/$2" label=$3 from=$4 to=$5 fallback=${6:-}
  part="$f.part"
  # Ein Platzhalter aus einem früheren Lauf zählt nicht als vorhandene Kopie
  if [ -e "$f.placeholder" ]; then rm -f "$f" "$f.placeholder"; fi

  progress "$from" "$label: Server fragen"
  if [ -s "$f" ] && [ ! -e "$part" ]; then
    # Vorhandene Datei: nur laden, wenn auf dem Server neuer
    # shellcheck disable=SC2086
    code=$(curl -sSIL $PROBE -o /dev/null -w '%{http_code}' -z "$f" "$url" 2>/dev/null) || code=000
    case "$code" in
      304)
        progress "$to" "$label aktuell"
        return 0
        ;;
      200) ;;
      *)
        unavailable
        return 0
        ;;
    esac
  fi
  # shellcheck disable=SC2086
  if ! headers=$(curl -fsSIL $PROBE "$url" 2>/dev/null); then
    unavailable
    return 0
  fi
  size=$(printf '%s\n' "$headers" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)
  size=${size:-0}
  echo "Lade $label ($((size / 1048576)) MB) von $url"
  # -C - setzt einen abgebrochenen Download fort; --retry-all-errors auch bei Zeitüberschreitung
  curl -fsSL --retry 2 --retry-delay 5 --retry-all-errors --connect-timeout 10 --speed-limit 1024 --speed-time 120 -C - -o "$part" "$url" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    have=$(stat -c %s "$part" 2>/dev/null || echo 0)
    pct=0
    [ "$size" -gt 0 ] && pct=$((have * 100 / size))
    [ "$pct" -gt 100 ] && pct=100
    progress $((from + (to - from) * pct / 100)) "$label ($((have / 1048576)) von $((size / 1048576)) MB)"
    sleep 3
  done
  if wait "$pid"; then
    mv "$part" "$f"
    progress "$to" "$label geladen"
  else
    unavailable
  fi
}

fetch "${WATER_URL:-https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip}" water-polygons-split-3857.zip "Wasserflächen" 2 75 empty_water
fetch "${NATURAL_EARTH_URL:-https://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip}" natural_earth_vector.sqlite.zip "Natural Earth" 75 97
fetch "${LAKES_URL:-https://github.com/acalcutt/osm-lakelines/releases/download/v12/lake_centerline.shp.zip}" lake_centerline.shp.zip "Seenbeschriftung" 97 99
progress 100 "Zusatzdaten bereit"
