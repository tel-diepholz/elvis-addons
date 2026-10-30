# Addon „Luftbilder (Orthophotos)“

Die Vermessungsverwaltungen der Länder veröffentlichen digitale Orthophotos (DOP) als Open Data. Dieses Addon zeigt
deren Abdeckung auf einer Karte. Ausgewählte Luftbilder lädt es einzeln, wandelt sie in lokale XYZ-Kacheln um und
stellt sie in ELVIS als Kartenstil „Luftbild (lokal)“ bereit (Karte und Druck).

## Ablauf

1. Nach der Installation läuft sofort der Tileserver, und der Kartenstil ist auswählbar. Anfangs ist er leer
   (transparente Kacheln). Beim ersten Start lädt das Addon den Kachelindex (Niedersachsen: ca. 83 MB, 30.865
   Luftbilder, je Kachel gilt die neueste Befliegung).
2. *Verwaltung → Addons → Luftbilder*: Die Karte „Luftbilder auswählen“ zeigt die Abdeckung. Ein Klick wählt ein
   Luftbild aus oder ab, Umschalt + Ziehen wählt mehrere aus, Umschalt + Alt + Ziehen wählt ab. „Übernehmen“ startet
   die Umwandlung bzw. löscht abgewählte Luftbilder.
3. Ausgewählte Luftbilder werden nacheinander geladen und mit GDAL umgewandelt (`gdalbuildvrt` nur RGB + Alpha →
   `gdalwarp` EPSG:3857 → `gdal2tiles.py --xyz`). Fortschritt und Speicherbedarf stehen oben auf der Seite.
4. Gibt es nach „Index neu laden“ eine neuere Befliegung, wird das Luftbild markiert. „Neuere Fassungen laden“
   wandelt diese Luftbilder neu um, bis dahin bleibt die alte Fassung sichtbar.

## Aufbau

- `addon.yaml`: ein Container (`ghcr.io/osgeo/gdal`), `provides.mapSources` und `provides.ui` (Bedienseite, von
  ELVIS nur für Admins weitergeleitet)
- `files/server/app.py`: Tileserver, API und Umwandlung (Python-Standardbibliothek + GDAL/numpy aus dem Image),
  Zustand in `/data/state.db`
- `files/server/sources.py`: Quellen-Adapter, je Land ein Kachelindex mit Umriss, Datum und Download-Adresse
- `files/ui/`: Bedienseite (Leaflet 1.9.4 mitgeliefert, funktioniert offline). Die Grundkarte kommt über den
  Kachelproxy von ELVIS.

Im Volume liegen je Luftbild eine eigene Pyramide (`pyramids/<id>/z/x/y.png`). Kacheln, zu denen mehrere Luftbilder
beitragen, setzt der Server beim Abruf über den Alphakanal zusammen und legt sie in `cache/` ab. Oberhalb der größten
Zoomstufe werden Kacheln bis Stufe 22 vergrößert, unterhalb der kleinsten bleiben sie leer.

## Quellen

| Land | Produkt | Index | Lizenz |
|---|---|---|---|
| Niedersachsen | LGLN DOP20 RGB (1- bzw. 2-km-Kacheln, JPEG-GeoTIFF, ca. 5 MB/km²) | [GeoJSON](https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/dop20/lgln-opengeodata-dop20.geojson) | CC BY 4.0 |

Weitere Länder brauchen einen Eintrag in `SOURCES` und ggf. einen eigenen Leser in `sources.py`. Beim Weitergeben der
Kacheln die Namensnennung des Landes beachten.

## Speicherbedarf

Je km² etwa 18 MB bei Zoomstufe 12–18 und etwa 70 MB bei 12–19 (PNG, gemessen bei Diepholz). Der Download wird nach der Umwandlung gelöscht.

## Update von Version 1.x

Version 1 lud ganze Bundesländer per Regex-Filter. Deren Daten (`src/`, `tiles/`) werden nicht mehr genutzt. Die
Bedienseite zeigt ihre Größe und bietet „Alte Daten aus Version 1 löschen“ an.
