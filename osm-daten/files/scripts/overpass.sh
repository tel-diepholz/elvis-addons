#!/bin/bash
# Overpass-Datenbank aus den zusammengeführten OSM-Daten bauen (/db/next, aktiviert wird später).
# Läuft im Overpass-Image (wiktorn/overpass-api), das osmium und update_database mitbringt. Ohne Metadaten und
# Versionsgeschichte, ohne Diffs: Der Stand ändert sich nur mit dem nächsten Bau.
set -euo pipefail
exec 3>&1
progress() { echo "ELVIS_PROGRESS $1 $2" >&3; }

W=/data/work
N=/db/next
if cmp -s "$W/stamp" /db/stamp 2>/dev/null; then
  echo "Regionen unverändert – vorhandene Overpass-Datenbank bleibt."
  progress 100 "Overpass aktuell"
  exit 0
fi
rm -rf "$N"
mkdir -p "$N/db"

progress 1 "Datenstand ermitteln"
version=$(osmium fileinfo -e -g data.timestamp.last "$W/input.osm.pbf")
echo "Datenstand $version"

progress 5 "OSM-Daten einlesen (dauert)"
# Wie init_osm3s.sh des Images, nur direkt aus der PBF-Datei
osmium cat "$W/input.osm.pbf" -f osm -o - \
  | /app/bin/update_database --db-dir="$N/db/" --version="$version" \
      --compression-method=gz --map-compression-method=gz --flush-size=16

progress 95 "Regeln für Gebiete übernehmen"
cp -r /app/etc/rules "$N/db"
echo "$version" > "$N/db/replicate_id"
cp "$W/stamp" "$N/stamp"
chown -R overpass:overpass "$N"
progress 100 "Overpass-Datenbank fertig ($(du -sm "$N" | cut -f1) MB)"
