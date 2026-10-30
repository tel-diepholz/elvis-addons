"""Quellen für Orthophotos: je Land ein Adapter, der den Kachelindex in die Tabelle „images“ schreibt.

Ein Eintrag ist ein einzeln ladbares Luftbild mit Umriss (WGS84-Bbox), Aufnahmedatum und Download-Adresse.
"""
import os, urllib.request
from osgeo import ogr, osr

ogr.UseExceptions()
osr.UseExceptions()

SOURCES = {
    'ni': {
        'name': 'Niedersachsen',
        'agency': 'LGLN',
        'license': 'CC BY 4.0',
        'product': 'DOP20 RGB',
        # GeoJSON mit einer 1-km-Kachel je Feature (tile_id, Aktualitaet, rgb = GeoTIFF), EPSG:25832, ca. 83 MB
        'index': 'https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/dop20/lgln-opengeodata-dop20.geojson',
        # grobe Downloadgröße je km² für die Anzeige vor dem Laden (JPEG-komprimierte GeoTIFFs, 1- oder 2-km-Kacheln)
        'mb_per_km2': 5,
    },
}

USER_AGENT = 'ELVIS-orthophotos/2.0'


def download(url, dest, progress=None, cancelled=None):
    """Lädt url nach dest (erst .part, dann umbenennen). progress(anteil) wird mit 0..1 aufgerufen."""
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest + '.part', 'wb') as f:
        total, done = int(r.headers.get('Content-Length') or 0), 0
        while chunk := r.read(1 << 20):
            if cancelled and cancelled():
                raise InterruptedError('abgebrochen')
            f.write(chunk)
            done += len(chunk)
            if progress and total:
                progress(done / total)
    os.replace(dest + '.part', dest)
    return done


def load_index(db, sid, workdir, progress):
    """Lädt den Index der Quelle sid und gleicht ihn mit der Tabelle ab (Status der Luftbilder bleibt erhalten)."""
    src = SOURCES[sid]
    os.makedirs(workdir, exist_ok=True)
    path = f'{workdir}/{sid}.geojson'
    download(src['index'], path, lambda f: progress(f * 0.6, 'Index herunterladen'))

    # OGR liest große GeoJSON-Dateien streamend
    ds = ogr.Open(path)
    layer = ds.GetLayer(0)
    srs = layer.GetSpatialRef()
    wgs84 = osr.SpatialReference()
    wgs84.ImportFromEPSG(4326)
    wgs84.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    if srs:
        srs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    tr = osr.CoordinateTransformation(srs, wgs84) if srs else None
    total = layer.GetFeatureCount() or 1
    # Je Kachel gibt es teils mehrere Befliegungen – die neueste gilt
    rows = {}
    for i, feat in enumerate(layer):
        geom = feat.GetGeometryRef()
        url = feat.GetField('rgb')
        if geom is None or not url:
            continue
        geom = geom.Clone()
        if tr:
            geom.Transform(tr)
        minlon, maxlon, minlat, maxlat = geom.GetEnvelope()
        date = (feat.GetField('Aktualitaet') or '')[:10].replace('/', '-')
        image_id = f"{sid}-{feat.GetField('tile_id')}"
        if image_id not in rows or rows[image_id][2] < date:
            rows[image_id] = (image_id, sid, date, url, minlon, minlat, maxlon, maxlat)
        if i % 2000 == 0:
            progress(0.6 + 0.35 * i / total, 'Index einlesen')
    ds = None
    progress(0.95, 'Index speichern')
    db.upsert_images(sid, list(rows.values()))
    os.remove(path)
    return len(rows)
