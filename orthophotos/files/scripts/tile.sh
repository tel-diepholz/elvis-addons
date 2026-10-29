#!/bin/sh
# Erzeugt aus allen geladenen Dateien eine gemeinsame XYZ-Kachelpyramide (PNG, EPSG:3857).
# Je Bundesland ein eigener Lauf: die Länder nutzen unterschiedliche Koordinatensysteme, und ein
# gemeinsames Mosaik würde z. B. bei NRW + Brandenburg das ganze leere Gebiet dazwischen kacheln.
set -eu
cd /data
rm -rf work-* tiles.new
mkdir tiles.new
n=0
for d in src/*/; do
  sid=$(basename "$d")
  find "$d" -type f \( -iname '*.tif' -o -iname '*.tiff' -o -iname '*.jp2' -o -iname '*.jpg' -o -iname '*.jpeg' \) > "work-$sid.txt"
  [ -s "work-$sid.txt" ] || continue
  n=$((n + 1))
  echo "ELVIS_PROGRESS 0 $sid"
  # Nur RGB: viele Länder liefern RGBI, der Infrarotkanal würde sonst als Transparenz gelesen.
  # JPG + Weltdatei kennen ihr Koordinatensystem nicht – aus dem Katalog zuweisen.
  if [ -f "$d/srs.txt" ]; then
    gdalbuildvrt -b 1 -b 2 -b 3 -addalpha -a_srs "$(cat "$d/srs.txt")" -input_file_list "work-$sid.txt" "work-$sid.vrt"
  else
    gdalbuildvrt -b 1 -b 2 -b 3 -addalpha -input_file_list "work-$sid.txt" "work-$sid.vrt"
  fi
  gdalwarp -of VRT -t_srs EPSG:3857 -r bilinear "work-$sid.vrt" "work-$sid-3857.vrt"
  gdal2tiles.py --xyz --processes="${PROCESSES:-2}" -z "${MIN_ZOOM:-10}-${MAX_ZOOM:-19}" --webviewer=none "work-$sid-3857.vrt" "work-tiles-$sid"
  # Kacheln an Landesgrenzen gibt es in beiden Ländern – übereinanderlegen statt überschreiben
  python3 /data/addon/scripts/merge.py "work-tiles-$sid" tiles.new
  rm -rf "work-tiles-$sid"
done
[ "$n" -gt 0 ] || { echo 'Keine Quelldateien gefunden'; exit 1; }
# Erst nach erfolgreichem Lauf austauschen, damit die Karte nie halb leer ist
rm -rf tiles && mv tiles.new tiles
echo 'ELVIS_PROGRESS 100 fertig'
