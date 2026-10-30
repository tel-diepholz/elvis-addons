#!/bin/sh
# OSM-Auszüge der gewählten Regionen von Geofabrik laden und zu einer Datei für alle Dienste zusammenführen.
# Geladen wird nur, was noch fehlt (bzw. alles bei REFRESH=true); abgewählte Regionen werden gelöscht.
# REGIONS, EXTRA_REGIONS: kommagetrennte Geofabrik-Pfade, z. B. "europe/germany/thueringen,africa/mali"
#
# Ergebnis in /data/work:
#   input.osm.pbf  alle Regionen zusammengeführt
#   stamp          Region, Größe und Stand je Auszug – die Dienste bauen nur neu, wenn er sich geändert hat
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }

O=/data/osm
W=/data/work
mkdir -p "$O" "$W"
# Reste abgebrochener Läufe (aktive Daten der Dienste bleiben)
rm -f "$W"/input.osm.pbf "$W"/osm.mbtiles "$W"/osm.mbtiles-* "$O"/*.part
rm -rf /data/tmp

# Freier Platz in MB auf dem Dateisystem von $1
free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }
file_of() { echo "$O/$(echo "$1" | tr '/' '_').osm.pbf"; }
url_of() { echo "https://download.geofabrik.de/$1-latest.osm.pbf"; }
remote_size() { curl -fsSIL --connect-timeout 30 --retry 3 "$(url_of "$1")" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1; }

# Vor apt prüfen: Bei vollem Speicher meldet apt sonst irreführend „invalid signature“
for fs in / /data; do
  if [ "$(free_mb "$fs")" -lt 500 ]; then
    echo "FEHLER: Auf dem Docker-Host ist kaum noch Speicher frei ($(free_mb "$fs") MB auf $( [ "$fs" = / ] && echo 'dem Docker-Speicher' || echo 'dem Addon-Volume')). Platz schaffen, z. B. mit 'docker system prune', und den Job erneut starten."
    exit 1
  fi
done

progress 1 "Werkzeuge installieren"
# osmium-tool gibt es nicht für Alpine, daher läuft dieser Schritt auf Debian
. /data/addon/scripts/tools.sh
install_debian_tools

# Gewünschte Regionen: Auswahl und freie Eingabe, ohne Doppelte
regions=$(echo "${REGIONS:-},${EXTRA_REGIONS:-}" | tr ', ' '\n\n' | sed '/^$/d' | awk '!seen[$0]++')
[ -n "$regions" ] || { echo "FEHLER: keine Region gewählt"; exit 1; }

# Abgewählte Regionen löschen
for f in "$O"/*.osm.pbf; do
  [ -e "$f" ] || continue
  keep=
  for r in $regions; do [ "$f" = "$(file_of "$r")" ] && keep=1; done
  if [ -z "$keep" ]; then
    echo "Region $(basename "$f" .osm.pbf | tr '_' '/') nicht mehr gewählt – entfernt"
    rm -f "$f"
  fi
done

# Zu ladende Regionen und Platzbedarf
fetch=""
fetch_mb=0
total_mb=0
for r in $regions; do
  f=$(file_of "$r")
  if [ -s "$f" ] && [ "${REFRESH:-false}" != "true" ]; then
    total_mb=$((total_mb + $(stat -c %s "$f") / 1048576))
    continue
  fi
  s=$(remote_size "$r" || true)
  if [ -z "$s" ]; then
    echo "FEHLER: Region „$r“ gibt es bei Geofabrik nicht ($(url_of "$r")). Pfad wie auf download.geofabrik.de angeben, z. B. europe/austria oder africa/mali."
    exit 1
  fi
  fetch="$fetch $r"
  fetch_mb=$((fetch_mb + s / 1048576))
  total_mb=$((total_mb + s / 1048576))
done
# Zusammenführen 1×, Kacheln 3×, Routing 1×, Overpass 4×, Ortssuche bis 22× (nur für neue Daten) plus Reserve
need_mb=$((fetch_mb + total_mb * 9 + fetch_mb * 22 + 2048))
have_mb=$(free_mb /data)
echo "Regionen: $(echo $regions | tr ' ' ',') – zusammen $total_mb MB, neu zu laden $fetch_mb MB"
echo "Benötigt etwa $need_mb MB, frei $have_mb MB"
if [ "$have_mb" -lt "$need_mb" ]; then
  echo "FEHLER: Zu wenig Speicher auf dem Docker-Host: etwa $need_mb MB nötig, $have_mb MB frei. Weniger Regionen wählen oder Platz schaffen (z. B. 'docker system prune')."
  exit 1
fi

n=$(echo $fetch | wc -w)
i=0
for r in $fetch; do
  url=$(url_of "$r")
  f=$(file_of "$r")
  size=$(remote_size "$r")
  size=${size:-0}
  echo "Lade $r ($((size / 1048576)) MB) von $url"
  curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 10 --retry-all-errors -o "$f.part" "$url" &
  pid=$!
  # Fortschritt aus der Dateigröße: Download ist 2–85 % dieses Schritts
  while kill -0 "$pid" 2>/dev/null; do
    have=$(stat -c %s "$f.part" 2>/dev/null || echo 0)
    part=0
    [ "$size" -gt 0 ] && part=$((have * 100 / size))
    progress $((2 + (i * 100 + part) * 83 / (n * 100))) "Lade $r ($((have / 1048576)) von $((size / 1048576)) MB)"
    sleep 3
  done
  wait "$pid"
  mv "$f.part" "$f"
  i=$((i + 1))
done

# Stand je Region: Dienste vergleichen ihn mit dem Stand ihrer aktiven Daten
: > "$W/stamp.new"
files=""
for r in $regions; do
  f=$(file_of "$r")
  echo "$r $(stat -c '%s %Y' "$f")" >> "$W/stamp.new"
  files="$files $f"
done
mv "$W/stamp.new" "$W/stamp"

# shellcheck disable=SC2086
set -- $files
if [ $# -gt 1 ]; then
  progress 88 "$# Regionen zusammenführen"
  osmium merge "$@" -o "$W/input.osm.pbf" --overwrite
else
  # Gleiches Dateisystem: harter Link statt Kopie
  ln -f "$1" "$W/input.osm.pbf"
fi
chmod 644 "$W/input.osm.pbf"
progress 100 "OSM-Daten bereit ($(($(stat -c %s "$W/input.osm.pbf") / 1048576)) MB)"
