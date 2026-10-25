#!/bin/sh
# Neu gebaute Daten aktivieren (Kacheln, Routing, Overpass); die Dienste werden danach von ELVIS neu gestartet.
# Die Ortssuche hat ihre Datenbank schon im eigenen Schritt aktualisiert.
set -eu
W=/data/work
[ -s "$W/osm.mbtiles" ] || { echo "FEHLER: keine erzeugten Kacheln gefunden"; exit 1; }
mv -f "$W/osm.mbtiles" /data/tiles/osm.mbtiles

if [ -d "$W/valhalla" ]; then
  rm -rf /data/valhalla.old
  [ -d /data/valhalla ] && mv /data/valhalla /data/valhalla.old
  mv "$W/valhalla" /data/valhalla
  sed -i 's|/data/work/valhalla|/data/valhalla|g' /data/valhalla/valhalla.json
  rm -rf /data/valhalla.old
fi

if [ -d /db/next ]; then
  rm -rf /db/db.old
  [ -d /db/db ] && mv /db/db /db/db.old
  mv /db/next/db /db/db
  mv /db/next/stamp /db/stamp
  # Vom Start-Skript des Images erwartet; ohne Diff-Adresse holt es keine Änderungen
  mkdir -p /db/diffs
  touch /db/changes.log /db/init_done
  [ -f /db/cookie.jar ] || echo "# Netscape HTTP Cookie File" > /db/cookie.jar
  # Benutzer „overpass“ des Images (hier unbekannt): Eigentümer der gebauten Datenbank übernehmen
  chown -R "$(stat -c %u:%g /db/db)" /db/diffs /db/changes.log /db/cookie.jar /db/stamp
  rm -rf /db/next /db/db.old
fi

rm -f "$W/input.osm.pbf"
{
  echo "Gebaut: $(date -Iseconds)"
  echo "Regionen:"
  awk '{print "  " $1}' "$W/stamp"
} > /data/last-build.txt
cat /data/last-build.txt
echo "ELVIS_PROGRESS 100 Neue Kartendaten aktiv ($(($(stat -c %s /data/tiles/osm.mbtiles) / 1048576)) MB Kacheln)"
