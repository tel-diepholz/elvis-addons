#!/bin/sh
# Neu erzeugte Kacheln aktivieren; der Kartenserver wird danach von ELVIS neu gestartet.
set -eu
[ -s /data/work/osm.mbtiles ] || { echo "FEHLER: keine erzeugten Kacheln gefunden"; exit 1; }
mv -f /data/work/osm.mbtiles /data/osm.mbtiles
rm -f /data/work/input.osm.pbf
date -Iseconds > /data/last-update.txt
echo "ELVIS_PROGRESS 100 Neue Kartendaten aktiv ($(($(stat -c %s /data/osm.mbtiles) / 1048576)) MB)"
