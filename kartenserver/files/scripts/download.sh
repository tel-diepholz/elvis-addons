#!/bin/sh
# OSM-Auszüge der gewählten Regionen von Geofabrik laden und bei Bedarf zusammenführen.
# REGIONS: kommagetrennte Geofabrik-Pfade unterhalb von europe/, z. B. "germany/thueringen,germany/hessen"
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }

W=/data/work
mkdir -p "$W"
# Reste abgebrochener Läufe (die aktive Karte /data/osm.mbtiles bleibt)
rm -f "$W"/*.osm.pbf "$W"/osm.mbtiles "$W"/osm.mbtiles-*
rm -rf /data/tmp

# Freier Platz in MB auf dem Dateisystem von $1
free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

# Vor apt prüfen: Bei vollem Speicher meldet apt sonst irreführend „invalid signature“
for fs in / /data; do
  if [ "$(free_mb "$fs")" -lt 500 ]; then
    echo "FEHLER: Auf dem Docker-Host ist kaum noch Speicher frei ($(free_mb "$fs") MB auf $( [ "$fs" = / ] && echo 'dem Docker-Speicher' || echo 'dem Addon-Volume')). Platz schaffen, z. B. mit 'docker system prune', und den Job erneut starten."
    exit 1
  fi
done

progress 1 "Werkzeuge installieren"
# osmium-tool gibt es nicht für Alpine, daher läuft dieser Schritt auf Debian
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq >/dev/null 2>/tmp/apt.err || grep -q '^E:' /tmp/apt.err; then
  cat /tmp/apt.err
  echo "FEHLER: Paketquellen nicht lesbar. Häufigste Ursache bei 'invalid signature': voller Speicher auf dem Docker-Host (df -h, docker system df) – sonst falsche Uhrzeit des Hosts oder ein Proxy, der die Antworten verändert."
  exit 1
fi
apt-get install -y -qq --no-install-recommends curl ca-certificates osmium-tool >/dev/null

regions=$(echo "${REGIONS:-}" | tr ',' ' ')
[ -n "$regions" ] || { echo "FEHLER: keine Region gewählt"; exit 1; }
n=$(echo "$regions" | wc -w)

# Größen vorab ermitteln, um den Platzbedarf zu prüfen
total=0
for r in $regions; do
  s=$(curl -fsSIL --retry 3 "https://download.geofabrik.de/europe/$r-latest.osm.pbf" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)
  total=$((total + ${s:-0}))
done
total_mb=$((total / 1048576))
# Download + Zusammenführen (2×) und Planetiler (Zwischendaten und Ergebnis, grob 3×) plus Reserve
need_mb=$((total_mb * 5 + 1024))
have_mb=$(free_mb /data)
echo "OSM-Daten: $total_mb MB, benötigt etwa $need_mb MB, frei $have_mb MB"
if [ "$have_mb" -lt "$need_mb" ]; then
  echo "FEHLER: Zu wenig Speicher auf dem Docker-Host: etwa $need_mb MB nötig, $have_mb MB frei. Weniger Regionen wählen oder Platz schaffen (z. B. 'docker system prune')."
  exit 1
fi

i=0
files=""
for r in $regions; do
  url="https://download.geofabrik.de/europe/$r-latest.osm.pbf"
  f="$W/$(echo "$r" | tr '/' '_').osm.pbf"
  size=$(curl -fsSIL --retry 3 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)
  size=${size:-0}
  echo "Lade $r ($((size / 1048576)) MB) von $url"
  curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "$f" "$url" &
  pid=$!
  # Fortschritt aus der Dateigröße: Download ist 0–85 % dieses Schritts
  while kill -0 "$pid" 2>/dev/null; do
    have=$(stat -c %s "$f" 2>/dev/null || echo 0)
    part=0
    [ "$size" -gt 0 ] && part=$((have * 100 / size))
    progress $(((i * 100 + part) * 85 / (n * 100))) "Lade $r ($((have / 1048576)) von $((size / 1048576)) MB)"
    sleep 3
  done
  wait "$pid"
  i=$((i + 1))
  files="$files $f"
done

# shellcheck disable=SC2086
set -- $files
if [ $# -gt 1 ]; then
  progress 88 "$# Regionen zusammenführen"
  osmium merge "$@" -o "$W/input.osm.pbf" --overwrite
  rm -f "$@"
else
  mv "$1" "$W/input.osm.pbf"
fi
progress 100 "OSM-Daten bereit ($(($(stat -c %s "$W/input.osm.pbf") / 1048576)) MB)"
