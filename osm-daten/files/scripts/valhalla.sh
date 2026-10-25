#!/bin/sh
# Routing-Graph für Valhalla aus den zusammengeführten OSM-Daten bauen (/data/work/valhalla, aktiviert wird später).
# Ohne Höhendaten und Zeitzonen – beides bräuchte zusätzliche Downloads und ist für Fahrtrouten verzichtbar.
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }

W=/data/work
B=$W/valhalla
if cmp -s "$W/stamp" /data/valhalla/stamp 2>/dev/null; then
  echo "Regionen unverändert – vorhandener Routing-Graph bleibt."
  progress 100 "Routing aktuell"
  exit 0
fi
rm -rf "$B"
mkdir -p "$B/tiles"

progress 1 "Konfiguration"
# Pfade unter /data/work/valhalla; beim Aktivieren wird daraus /data/valhalla
valhalla_build_config \
  --mjolnir-tile-dir "$B/tiles" \
  --mjolnir-tile-extract "$B/tiles.tar" \
  --mjolnir-admin "$B/admins.sqlite" \
  --mjolnir-concurrency "$(nproc)" \
  > "$B/valhalla.json"

progress 3 "Verwaltungsgrenzen"
valhalla_build_admins -c "$B/valhalla.json" "$W/input.osm.pbf"

progress 10 "Straßennetz aufbauen"
valhalla_build_tiles -c "$B/valhalla.json" "$W/input.osm.pbf"

progress 92 "Routing-Graph packen"
valhalla_build_extract -c "$B/valhalla.json" -v --overwrite
rm -rf "$B/tiles"
cp "$W/stamp" "$B/stamp"
progress 100 "Routing-Graph fertig ($(($(stat -c %s "$B/tiles.tar") / 1048576)) MB)"
