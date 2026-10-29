#!/usr/bin/env python3
"""Lädt Orthophoto-Dateien (GeoTIFF/JP2/JPG, auch in ZIP-Paketen) der gewählten Bundesländer.

Umgebung: STATES (kommagetrennt), FEED_OVERRIDE (id=url,id=url), FILTER (Regex auf Dateinamen), MAX_FILES, REFRESH.
Ein Feed ist entweder ein Verzeichnis-Index mit Links oder ein direkter Link auf eine Datei (z. B. ZIP);
mehrere Adressen je Land sind mit Leerzeichen getrennt möglich.
Fortschritt: Zeilen „ELVIS_PROGRESS <prozent> <text>“.
"""
import json, os, re, shutil, sys, urllib.parse, urllib.request, zipfile

DATA = '/data'
IMAGE = re.compile(r'\.(tif|tiff|jp2|jpg|jpeg)$', re.I)
# Weltdateien und Projektionsangaben gehören zum gleichnamigen Bild
SIDECAR = re.compile(r'\.(wld|tfw|jgw|j2w|prj|aux\.xml)$', re.I)
ARCHIVE = re.compile(r'\.zip$', re.I)
# HTML-Verzeichnis (href) oder XML-Dateiliste wie bei opengeodata.nrw.de (<file name=…>)
HREF = re.compile(r'(?:href|<file\s+name)="([^"]+)"', re.I)


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'ELVIS-orthophotos/1.1'})
    return urllib.request.urlopen(req, timeout=60)


def name_of(url):
    return os.path.basename(urllib.parse.urlparse(url).path)


def links(feed, keep):
    # Ein direkter Link wird immer geladen (ein ZIP wird dann beim Entpacken gefiltert),
    # aus einem Verzeichnis nur die Dateien, deren Name passt
    if IMAGE.search(name_of(feed)) or ARCHIVE.search(name_of(feed)):
        return [feed]
    html = get(feed).read().decode('utf-8', 'replace')
    out = set()
    for h in HREF.findall(html):
        full = urllib.parse.urljoin(feed, h)
        if (IMAGE.search(name_of(full)) or ARCHIVE.search(name_of(full))) and keep(name_of(full)):
            out.add(full)
    return sorted(out)


def unpack(path, dest, keep):
    """Entpackt Bilder und Weltdateien (auch aus verschachtelten ZIPs) und löscht das Archiv."""
    nested = []
    with zipfile.ZipFile(path) as z:
        for m in z.infolist():
            name = os.path.basename(m.filename)
            if m.is_dir() or not name:
                continue
            if ARCHIVE.search(name):
                nested.append(f'{dest}/{name}')
            elif not ((IMAGE.search(name) or SIDECAR.search(name)) and keep(name)):
                continue
            with z.open(m) as src, open(f'{dest}/{name}', 'wb') as f:
                shutil.copyfileobj(src, f)
    os.remove(path)
    for n in nested:
        unpack(n, dest, keep)


def download(url, dest, progress):
    with get(url) as r, open(dest + '.part', 'wb') as f:
        total, done, last = int(r.headers.get('Content-Length') or 0), 0, -1
        while chunk := r.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            if total and (pct := 100 * done // total) != last:
                last = pct
                progress(done / total)
    os.replace(dest + '.part', dest)


def main():
    catalog = {s['id']: s for s in json.load(open(f'{DATA}/addon/catalog.json'))['states']}
    states = [s for s in os.environ.get('STATES', '').split(',') if s]
    override = dict(p.split('=', 1) for p in os.environ.get('FEED_OVERRIDE', '').split(',') if '=' in p)
    flt = re.compile(os.environ['FILTER']) if os.environ.get('FILTER') else None
    limit = int(os.environ.get('MAX_FILES') or 0)
    refresh = os.environ.get('REFRESH') == 'true'
    keep = lambda name: not flt or bool(flt.search(name.split('.')[0]))
    if not states:
        sys.exit('Kein Bundesland gewählt')
    jobs = []
    for sid in states:
        if sid not in catalog:
            sys.exit(f'Unbekanntes Bundesland: {sid}')
        state = catalog[sid]
        feed = state['feed'] if isinstance(state['feed'], list) else [state['feed']]
        feeds = override[sid].split() if sid in override else [f for f in feed if f]
        if not feeds:
            sys.exit(f"Für {state['name']} ist keine Download-Adresse hinterlegt. Index-Adresse in „feedOverride“ angeben (Portal: {state['portal']}).")
        urls = [u for f in feeds for u in links(f, keep)]
        if limit:
            urls = urls[:limit]
        print(f"{state['name']}: {len(urls)} Dateien", flush=True)
        d = f'{DATA}/src/{sid}'
        os.makedirs(d, exist_ok=True)
        # Bilder ohne eingebettetes Koordinatensystem (JPG + Weltdatei) bekommen es beim Kacheln zugewiesen
        if state.get('srs'):
            with open(f'{d}/srs.txt', 'w') as f:
                f.write(state['srs'])
        jobs += [(sid, u) for u in urls]
    for i, (sid, url) in enumerate(jobs):
        d = f'{DATA}/src/{sid}'
        dest = f'{d}/{name_of(url)}'
        # Entpackte Archive verschwinden, eine Markierung merkt sich den Abschluss
        done = dest + '.done' if ARCHIVE.search(dest) else dest
        if not refresh and os.path.exists(done):
            continue
        progress = lambda frac: print(f'ELVIS_PROGRESS {int(100 * (i + frac) / len(jobs))} {name_of(url)}', flush=True)
        download(url, dest, progress)
        if ARCHIVE.search(dest):
            print(f'Entpacke {name_of(url)}', flush=True)
            unpack(dest, d, keep)
            open(done, 'w').close()
        progress(1)


main()
