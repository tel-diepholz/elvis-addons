# Addon „Luftbilder (Orthophotos der Länder)“

Die Vermessungsverwaltungen der Länder veröffentlichen digitale Orthophotos (DOP) als Open Data.
Dieses Addon lässt die Bundesländer auswählen, lädt die GeoTIFF/JP2-Dateien, erzeugt per GDAL
lokale XYZ-Kacheln und stellt sie über nginx bereit. ELVIS bindet sie als Kartenstil „Luftbild (lokal)“
ein (`provides.mapSources`, auch im Druck nutzbar).

- `addon.yaml` – Manifest (siehe `docs/addons/manifest.md`)
- `files/catalog.json` – Sammlung der Quellen aller 16 Länder (Behörde, Portal, Lizenz, Auflösung, Index-Adresse)
- `files/scripts/fetch.py` – Download aus dem Verzeichnis-Index (HTML oder XML-Dateiliste) oder von direkten Links, entpackt (auch verschachtelte) ZIP-Pakete (Filter, Höchstzahl, wiederaufnehmbar)
- `files/scripts/tile.sh` – je Land `gdalbuildvrt` (nur RGB, ggf. mit `srs` aus dem Katalog) → `gdalwarp` (EPSG:3857) → `gdal2tiles.py --xyz`
- `files/scripts/merge.py` – legt die Kacheln der Länder zusammen, an Landesgrenzen über den Alphakanal

## Stand / Einschränkungen

- Download-Adressen (`feed`) sind nur für NRW, Brandenburg und Bremen hinterlegt; für die übrigen Länder ist das Portal
  bekannt, die Adresse lässt sich per Option „Eigene Index-Adressen“ ergänzen. Alle drei sind gegen die Live-Dienste
  geprüft:
  - NRW: DOP10 RGBI als JP2 (1 km², ~30 MB je Kachel), EPSG:25832, XML-Dateiliste
  - Brandenburg: DOP20 RGBI als GeoTIFF in je einem ZIP pro km² (~80 MB), EPSG:25833
  - Bremen: DOP10 RGB als JPG + `.wld` in verschachtelten ZIPs, EPSG:25832, Stadt Bremen ~6 GB, Bremerhaven ~2 GB
- Der Dateifilter wirkt auf Dateinamen ohne Endung, z. B. NRW `^dop10rgbi_32_(28[0-9])_(565[0-9])_`, Brandenburg
  `^dop_33(25[0-9])-(588[0-9])$` (Kilometer-Koordinaten). Bremen wird immer komplett geladen und erst beim Entpacken gefiltert.
- Bayern, BW, Niedersachsen u. a. liefern teils nur Atom-Feeds oder Download-Seiten ohne Direktlinks; dafür muss
  `fetch.py` ggf. erweitert werden.
- Speicherbedarf: Landesweite Daten erreichen schnell Hunderte GB bis TB – Dateifilter und Zoomstufen nutzen.
- Beim Weitergeben der Kacheln Lizenz/Namensnennung des jeweiligen Landes beachten (`license` im Katalog).
