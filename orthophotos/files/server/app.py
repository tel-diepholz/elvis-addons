#!/usr/bin/env python3
"""Tileserver, Auswahl-API und Umwandlung einzelner Luftbilder.

- GET  /tiles/{z}/{x}/{y}.png  Kacheln aller umgewandelten Luftbilder (leer = transparent, nie 404)
- GET  /api/status             Index, Zähler, laufende Umwandlung, Speicher
- GET  /api/images?bbox=w,s,e,n&zoom=z   Luftbilder im Ausschnitt (darunter zusammengefasst)
- POST /api/selection {add, remove}      Luftbilder zum Umwandeln vormerken bzw. löschen
- POST /api/index/refresh, /api/retry {ids}, /api/legacy/delete
- sonst: Dateien der Oberfläche aus /data/addon/ui

Je Luftbild entsteht eine eigene XYZ-Pyramide (pyramids/<id>/z/x/y.png). Kacheln, zu denen mehrere Luftbilder
beitragen, werden beim Abruf über den Alphakanal zusammengesetzt und in cache/ abgelegt.
"""
import json, math, os, re, shutil, sqlite3, subprocess, sys, threading, time, traceback, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
from osgeo import gdal

sys.path.insert(0, os.path.dirname(__file__))
import sources  # noqa: E402

gdal.UseExceptions()

DATA = os.environ.get('DATA', '/data')
UI = f'{DATA}/addon/ui'
MIN_ZOOM = int(os.environ.get('MIN_ZOOM') or 12)
MAX_ZOOM = int(os.environ.get('MAX_ZOOM') or 19)
PROCESSES = int(os.environ.get('PROCESSES') or 2)
PORT = int(os.environ.get('PORT') or 8080)
# Bis zu dieser Zoomstufe werden darüber hinaus angeforderte Kacheln aus der größten Stufe vergrößert
OVERZOOM_MAX = 22
# Ab dieser Zoomstufe liefert /api/images einzelne Luftbilder, darunter ein grobes Raster
DETAIL_ZOOM = 11
DETAIL_LIMIT = 6000
LEGACY = ['src', 'tiles', 'addon/catalog.json', 'addon/scripts']
SELECTED = ('queued', 'downloading', 'converting', 'ready', 'error')
TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml'}


def log(*a):
    print(*a, flush=True)


# --- Kachelmathematik (Web-Mercator, XYZ) ---

def tile_bounds(z, x, y):
    n = 2 ** z
    lat = lambda t: math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * t / n))))
    return x / n * 360 - 180, lat(y + 1), (x + 1) / n * 360 - 180, lat(y)


def tile_range(z, minlon, minlat, maxlon, maxlat):
    n = 2 ** z
    tx = lambda lon: min(n - 1, max(0, int((lon + 180) / 360 * n)))
    ty = lambda lat: min(n - 1, max(0, int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)))
    return tx(minlon), ty(maxlat), tx(maxlon), ty(minlat)


# --- PNG lesen/schreiben über GDAL ---

def png_bytes(rgba):
    name = f'/vsimem/{uuid.uuid4().hex}.png'
    mem = gdal.GetDriverByName('MEM').Create('', rgba.shape[2], rgba.shape[1], 4, gdal.GDT_Byte)
    for i in range(4):
        mem.GetRasterBand(i + 1).WriteArray(rgba[i])
    gdal.GetDriverByName('PNG').CreateCopy(name, mem)
    f = gdal.VSIFOpenL(name, 'rb')
    gdal.VSIFSeekL(f, 0, 2)
    size = gdal.VSIFTellL(f)
    gdal.VSIFSeekL(f, 0, 0)
    data = gdal.VSIFReadL(1, size, f)
    gdal.VSIFCloseL(f)
    gdal.Unlink(name)
    return data


def read_rgba(path):
    a = gdal.Open(path).ReadAsArray()
    if a.ndim == 2:
        a = np.stack([a, a, a, np.full_like(a, 255)])
    elif a.shape[0] == 2:  # Grau + Alpha
        a = np.stack([a[0], a[0], a[0], a[1]])
    elif a.shape[0] == 3:
        a = np.concatenate([a, np.full_like(a[:1], 255)])
    return a[:4]


def compose(arrays):
    """Legt RGBA-Kacheln übereinander (die erste liegt oben), wie früher merge.py an Landesgrenzen."""
    out = arrays[-1].astype(np.float32)
    for s in reversed(arrays[:-1]):
        s = s.astype(np.float32)
        sa, da = s[3:] / 255, out[3:] / 255
        oa = sa + da * (1 - sa)
        rgb = (s[:3] * sa + out[:3] * da * (1 - sa)) / np.maximum(oa, 1e-6)
        out = np.concatenate([rgb, oa * 255])
    return out.round().clip(0, 255).astype(np.uint8)


BLANK = png_bytes(np.zeros((4, 256, 256), np.uint8))


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f'{path}.{uuid.uuid4().hex[:8]}.tmp'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def dir_size(path):
    total = 0
    if os.path.isfile(path):
        return os.path.getsize(path)
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


# --- Zustand ---

class Db:
    def __init__(self, path):
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.lock = threading.Lock()
        self.conn.execute('PRAGMA journal_mode=WAL')
        self.conn.executescript('''
            CREATE TABLE IF NOT EXISTS images (
              id TEXT PRIMARY KEY, source TEXT NOT NULL, date TEXT, url TEXT NOT NULL,
              minlon REAL, minlat REAL, maxlon REAL, maxlat REAL,
              status TEXT NOT NULL DEFAULT 'none', error TEXT, bytes INTEGER NOT NULL DEFAULT 0,
              built_date TEXT, updated REAL NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS images_lon ON images (minlon);
            CREATE INDEX IF NOT EXISTS images_status ON images (status);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        ''')

    def q(self, sql, args=()):
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def x(self, sql, args=()):
        with self.lock:
            return self.conn.execute(sql, args).rowcount

    def meta(self, key, value=None):
        if value is None:
            r = self.q('SELECT value FROM meta WHERE key = ?', (key,))
            return json.loads(r[0][0]) if r else None
        self.x('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', (key, json.dumps(value)))

    def upsert_images(self, sid, rows):
        with self.lock:
            c = self.conn
            c.execute('BEGIN')
            c.execute('CREATE TEMP TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY)')
            c.execute('DELETE FROM seen')
            c.executemany('INSERT OR IGNORE INTO seen VALUES (?)', [(r[0],) for r in rows])
            c.executemany('''INSERT INTO images (id, source, date, url, minlon, minlat, maxlon, maxlat) VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET date = excluded.date, url = excluded.url, minlon = excluded.minlon,
                minlat = excluded.minlat, maxlon = excluded.maxlon, maxlat = excluded.maxlat''', rows)
            # Nicht mehr angebotene Luftbilder vergessen, sofern sie nicht umgewandelt sind
            c.execute("DELETE FROM images WHERE source = ? AND status = 'none' AND id NOT IN (SELECT id FROM seen)", (sid,))
            c.execute('COMMIT')


class App:
    def __init__(self):
        for d in ('pyramids', 'cache', 'download', 'work', 'index'):
            os.makedirs(f'{DATA}/{d}', exist_ok=True)
        self.db = Db(f'{DATA}/state.db')
        self.wake = threading.Event()
        self.current = None  # {'id', 'stage', 'percent'}
        self.cancel = set()
        self.index = {'state': 'idle', 'percent': None, 'message': None, 'error': None}
        self.legacy_bytes = None
        self.built = {}
        self.built_lock = threading.Lock()
        # Abgebrochene Läufe aufräumen und erneut einreihen
        self.db.x("UPDATE images SET status = 'queued' WHERE status IN ('downloading', 'converting')")
        for d in ('download', 'work'):
            shutil.rmtree(f'{DATA}/{d}', ignore_errors=True)
            os.makedirs(f'{DATA}/{d}')
        for name in os.listdir(f'{DATA}/pyramids'):
            if name.endswith('.tmp') or name.endswith('.old'):
                shutil.rmtree(f'{DATA}/pyramids/{name}', ignore_errors=True)
        self.reload_built()

    def reload_built(self):
        rows = self.db.q('SELECT id, minlon, minlat, maxlon, maxlat FROM images WHERE built_date IS NOT NULL')
        with self.built_lock:
            self.built = {r[0]: r[1:] for r in rows}

    def start(self):
        threading.Thread(target=self.worker, daemon=True).start()
        threading.Thread(target=self.measure_legacy, daemon=True).start()
        if not self.db.q('SELECT 1 FROM images LIMIT 1'):
            self.refresh_index()

    # --- Index ---

    def refresh_index(self):
        if self.index['state'] == 'loading':
            return False
        self.index = {'state': 'loading', 'percent': 0, 'message': 'Start', 'error': None}
        threading.Thread(target=self._refresh_index, daemon=True).start()
        return True

    def _refresh_index(self):
        def progress(frac, msg):
            self.index.update(percent=round(frac * 100), message=msg)
        try:
            counts = {}
            for sid in sources.SOURCES:
                counts[sid] = sources.load_index(self.db, sid, f'{DATA}/index', progress)
                log(f'Index {sid}: {counts[sid]} Luftbilder')
            self.db.meta('index', {'loadedAt': time.strftime('%Y-%m-%dT%H:%M:%S'), 'counts': counts})
            self.index = {'state': 'idle', 'percent': None, 'message': None, 'error': None}
        except Exception as e:
            traceback.print_exc()
            self.index = {'state': 'error', 'percent': None, 'message': None, 'error': str(e)}

    # --- Alte Daten aus Version 1 ---

    def measure_legacy(self):
        self.legacy_bytes = sum(dir_size(f'{DATA}/{p}') for p in LEGACY if os.path.exists(f'{DATA}/{p}'))

    def delete_legacy(self):
        for p in LEGACY:
            path = f'{DATA}/{p}'
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.exists(path):
                os.remove(path)
        self.legacy_bytes = 0

    # --- Auswahl ---

    def select(self, add, remove, outdated=False):
        now = time.time()
        added = removed = 0
        if outdated:
            add = add + [r[0] for r in self.db.q("SELECT id FROM images WHERE status = 'ready' AND built_date < date")]
        for i in add:
            # Neu, fehlgeschlagen oder umgewandelt, aber inzwischen in neuerer Fassung verfügbar
            added += self.db.x("""UPDATE images SET status = 'queued', error = NULL, updated = ? WHERE id = ? AND
                (status IN ('none', 'error') OR (status = 'ready' AND built_date < date))""", (now, i))
        for i in remove:
            row = self.db.q('SELECT status FROM images WHERE id = ?', (i,))
            if not row or row[0][0] == 'none':
                continue
            if row[0][0] in ('downloading', 'converting'):
                self.cancel.add(i)
            self.drop(i)
            removed += 1
        if added:
            self.wake.set()
        return {'added': added, 'removed': removed}

    def drop(self, image_id):
        bbox = self.db.q('SELECT minlon, minlat, maxlon, maxlat FROM images WHERE id = ?', (image_id,))
        self.db.x("UPDATE images SET status = 'none', error = NULL, bytes = 0, built_date = NULL, updated = ? WHERE id = ?", (time.time(), image_id))
        with self.built_lock:
            self.built.pop(image_id, None)
        shutil.rmtree(f'{DATA}/pyramids/{image_id}', ignore_errors=True)
        if bbox:
            self.invalidate(*bbox[0])

    def retry(self, ids, everything=False):
        if everything:
            ids = [r[0] for r in self.db.q("SELECT id FROM images WHERE status = 'error'")]
        n = sum(self.db.x("UPDATE images SET status = 'queued', error = NULL, updated = ? WHERE id = ? AND status = 'error'", (time.time(), i)) for i in ids)
        if n:
            self.wake.set()
        return {'queued': n}

    def invalidate(self, minlon, minlat, maxlon, maxlat):
        """Zusammengesetzte Kacheln im Umriss eines Luftbilds verwerfen."""
        for z in range(MIN_ZOOM, OVERZOOM_MAX + 1):
            x0, y0, x1, y1 = tile_range(z, minlon, minlat, maxlon, maxlat)
            for x in range(x0, x1 + 1):
                for y in range(y0, y1 + 1):
                    try:
                        os.remove(f'{DATA}/cache/{z}/{x}/{y}.png')
                    except FileNotFoundError:
                        pass

    # --- Umwandlung ---

    def worker(self):
        while True:
            row = self.db.q("SELECT id, url, date, minlon, minlat, maxlon, maxlat FROM images WHERE status = 'queued' ORDER BY updated LIMIT 1")
            if not row:
                self.wake.wait(30)
                self.wake.clear()
                continue
            image_id, url, date, *bbox = row[0]
            self.cancel.discard(image_id)
            try:
                self.convert(image_id, url, date, bbox)
            except InterruptedError:
                log(f'{image_id}: abgebrochen')
            except Exception as e:
                traceback.print_exc()
                self.db.x("UPDATE images SET status = 'error', error = ?, updated = ? WHERE id = ? AND status IN ('downloading', 'converting')", (str(e)[:500], time.time(), image_id))
            finally:
                self.current = None
                for p in (f'{DATA}/download/{image_id}.tif', f'{DATA}/download/{image_id}.tif.part'):
                    if os.path.exists(p):
                        os.remove(p)
                for name in os.listdir(f'{DATA}/work'):
                    if name.startswith(image_id):
                        os.remove(f'{DATA}/work/{name}')
                shutil.rmtree(f'{DATA}/pyramids/{image_id}.tmp', ignore_errors=True)

    def stage(self, image_id, status, percent):
        if image_id in self.cancel:
            raise InterruptedError()
        self.current = {'id': image_id, 'stage': status, 'percent': percent}

    def convert(self, image_id, url, date, bbox):
        log(f'{image_id}: herunterladen {url}')
        self.db.x("UPDATE images SET status = 'downloading' WHERE id = ?", (image_id,))
        self.stage(image_id, 'downloading', 0)
        src = f'{DATA}/download/{image_id}.tif'
        sources.download(url, src, lambda f: self.stage(image_id, 'downloading', round(f * 100)), lambda: image_id in self.cancel)

        self.db.x("UPDATE images SET status = 'converting' WHERE id = ?", (image_id,))
        self.stage(image_id, 'converting', 0)
        vrt, vrt3857, out = f'{DATA}/work/{image_id}.vrt', f'{DATA}/work/{image_id}-3857.vrt', f'{DATA}/pyramids/{image_id}.tmp'
        # Nur RGB, der Rand wird über den Alphakanal transparent
        self.run(image_id, ['gdalbuildvrt', '-q', '-b', '1', '-b', '2', '-b', '3', '-addalpha', vrt, src])
        self.run(image_id, ['gdalwarp', '-q', '-of', 'VRT', '-t_srs', 'EPSG:3857', '-r', 'bilinear', vrt, vrt3857])
        self.run(image_id, ['gdal2tiles.py', '--xyz', '-x', f'--processes={PROCESSES}', '-z', f'{MIN_ZOOM}-{MAX_ZOOM}', '--webviewer=none', vrt3857, out], progress=True)

        if image_id in self.cancel:
            raise InterruptedError()
        final = f'{DATA}/pyramids/{image_id}'
        if os.path.exists(final):
            os.replace(final, final + '.old')
        os.replace(out, final)
        shutil.rmtree(final + '.old', ignore_errors=True)
        size = dir_size(final)
        n = self.db.x("UPDATE images SET status = 'ready', error = NULL, bytes = ?, built_date = ?, updated = ? WHERE id = ? AND status = 'converting'", (size, date, time.time(), image_id))
        if not n:  # inzwischen abgewählt
            shutil.rmtree(final, ignore_errors=True)
            raise InterruptedError()
        with self.built_lock:
            self.built[image_id] = tuple(bbox)
        self.invalidate(*bbox)
        log(f'{image_id}: fertig ({size // 1_000_000} MB)')

    def run(self, image_id, cmd, progress=False):
        # ungepuffert, damit der Fortschritt von gdal2tiles laufend ankommt
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, 'PYTHONUNBUFFERED': '1'})
        buf, phase, out = '', 0, []
        while True:
            chunk = proc.stdout.read1(256) if hasattr(proc.stdout, 'read1') else proc.stdout.read(256)
            if not chunk:
                break
            text = chunk.decode('utf-8', 'replace')
            out.append(text)
            if image_id in self.cancel:
                proc.kill()
                proc.wait()
                raise InterruptedError()
            if progress:
                buf = (buf + text)[-200:]
                if 'Overview' in buf and phase == 0:
                    phase, buf = 1, ''
                nums = re.findall(r'(\d+)\.\.\.|(\d+) - done', buf)
                if nums:
                    pct = int([n for n in nums[-1] if n][0])
                    self.stage(image_id, 'converting', round(pct * 0.8) if phase == 0 else 80 + round(pct * 0.2))
        if proc.wait() != 0:
            raise RuntimeError(f'{cmd[0]} fehlgeschlagen: {"".join(out)[-400:].strip()}')

    # --- Kacheln ---

    def tile(self, z, x, y):
        if z < MIN_ZOOM or z > OVERZOOM_MAX:
            return BLANK
        if z > MAX_ZOOM:
            return self.overzoom(z, x, y)
        minlon, minlat, maxlon, maxlat = tile_bounds(z, x, y)
        with self.built_lock:
            ids = [i for i, b in self.built.items() if b[0] < maxlon and b[2] > minlon and b[1] < maxlat and b[3] > minlat]
        files = [p for p in (f'{DATA}/pyramids/{i}/{z}/{x}/{y}.png' for i in sorted(ids)) if os.path.exists(p)]
        if not files:
            return BLANK
        if len(files) == 1:
            with open(files[0], 'rb') as f:
                return f.read()
        cached = f'{DATA}/cache/{z}/{x}/{y}.png'
        if os.path.exists(cached):
            with open(cached, 'rb') as f:
                return f.read()
        data = png_bytes(compose([read_rgba(p) for p in files]))
        write_atomic(cached, data)
        return data

    def overzoom(self, z, x, y):
        cached = f'{DATA}/cache/{z}/{x}/{y}.png'
        if os.path.exists(cached):
            with open(cached, 'rb') as f:
                return f.read()
        d = z - MAX_ZOOM
        parent = self.tile(MAX_ZOOM, x >> d, y >> d)
        if parent is BLANK:
            return BLANK
        name = f'/vsimem/{uuid.uuid4().hex}.png'
        gdal.FileFromMemBuffer(name, parent)
        a = read_rgba(name)
        gdal.Unlink(name)
        size = 256 >> d
        ox, oy = (x - ((x >> d) << d)) * size, (y - ((y >> d) << d)) * size
        part = a[:, oy:oy + size, ox:ox + size].repeat(1 << d, axis=1).repeat(1 << d, axis=2)
        data = png_bytes(part)
        write_atomic(cached, data)
        return data

    # --- Abfragen ---

    def status(self):
        counts = dict(self.db.q('SELECT status, COUNT(*) FROM images GROUP BY status'))
        total = sum(counts.values())
        ready_bytes = self.db.q("SELECT COALESCE(SUM(bytes), 0) FROM images WHERE built_date IS NOT NULL")[0][0]
        outdated = self.db.q("SELECT COUNT(*) FROM images WHERE built_date IS NOT NULL AND built_date < date")[0][0]
        bounds = self.db.q('SELECT MIN(minlon), MIN(minlat), MAX(maxlon), MAX(maxlat) FROM images')[0]
        built_bounds = self.db.q('SELECT MIN(minlon), MIN(minlat), MAX(maxlon), MAX(maxlat) FROM images WHERE built_date IS NOT NULL')[0]
        fs = os.statvfs(DATA)
        return {
            'index': {**self.index, **(self.db.meta('index') or {}), 'total': total},
            'counts': {k: counts.get(k, 0) for k in ('none',) + SELECTED},
            'outdated': outdated,
            'current': self.current,
            'bytes': ready_bytes,
            'free': fs.f_bavail * fs.f_frsize,
            'legacyBytes': self.legacy_bytes,
            'bounds': bounds if bounds[0] is not None else None,
            'builtBounds': built_bounds if built_bounds[0] is not None else None,
            'zoom': {'min': MIN_ZOOM, 'max': MAX_ZOOM},
            'sources': [{'id': k, **{f: v[f] for f in ('name', 'agency', 'license', 'product', 'mb_per_km2')}} for k, v in sources.SOURCES.items()],
        }

    def images(self, bbox, zoom):
        w, s, e, n = bbox
        if zoom >= DETAIL_ZOOM:
            rows = self.db.q('''SELECT id, minlon, minlat, maxlon, maxlat, status, date, built_date, error FROM images
                WHERE minlon < ? AND maxlon > ? AND minlat < ? AND maxlat > ? LIMIT ?''', (e, w, n, s, DETAIL_LIMIT + 1))
            return {'mode': 'detail', 'truncated': len(rows) > DETAIL_LIMIT, 'items': [list(r) for r in rows[:DETAIL_LIMIT]]}
        # Grobes Raster: Anzahl je Zelle (ca. 10 km), damit das ganze Land auf einmal darstellbar bleibt
        cw, ch = 0.15, 0.1
        rows = self.db.q(f'''SELECT CAST(minlon / {cw} AS INT), CAST(minlat / {ch} AS INT), COUNT(*),
                SUM(status IN ('queued', 'downloading', 'converting', 'error')), SUM(built_date IS NOT NULL)
            FROM images WHERE minlon < ? AND maxlon > ? AND minlat < ? AND maxlat > ? GROUP BY 1, 2''', (e, w, n, s))
        return {'mode': 'grid', 'items': [[cx * cw, cy * ch, (cx + 1) * cw, (cy + 1) * ch, t, p, r] for cx, cy, t, p, r in rows]}


# --- HTTP ---

APP: App = None  # type: ignore


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass

    def send(self, code, data, ctype, cache='no-cache'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', cache)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def json(self, obj, code=200):
        self.send(code, json.dumps(obj).encode(), 'application/json')

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}') if n else {}

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            u = urlparse(self.path)
            m = re.fullmatch(r'/tiles/(\d+)/(\d+)/(\d+)\.png', u.path)
            if m:
                return self.send(200, APP.tile(*map(int, m.groups())), 'image/png', 'public, max-age=60')
            if u.path == '/api/status':
                return self.json(APP.status())
            if u.path == '/api/images':
                q = parse_qs(u.query)
                bbox = [float(v) for v in q['bbox'][0].split(',')]
                return self.json(APP.images(bbox, int(float(q.get('zoom', ['0'])[0]))))
            self.static(u.path)
        except Exception as e:
            traceback.print_exc()
            self.json({'error': str(e)}, 500)

    def do_POST(self):
        try:
            path = urlparse(self.path).path
            body = self.body()
            if path == '/api/selection':
                return self.json(APP.select([str(i) for i in body.get('add', [])], [str(i) for i in body.get('remove', [])], bool(body.get('outdated'))))
            if path == '/api/retry':
                return self.json(APP.retry([str(i) for i in body.get('ids', [])], bool(body.get('all'))))
            if path == '/api/index/refresh':
                return self.json({'started': APP.refresh_index()})
            if path == '/api/legacy/delete':
                APP.delete_legacy()
                return self.json({'ok': True})
            self.json({'error': 'Nicht gefunden'}, 404)
        except Exception as e:
            traceback.print_exc()
            self.json({'error': str(e)}, 500)

    def static(self, path):
        rel = os.path.normpath(path.lstrip('/') or 'index.html')
        full = os.path.join(UI, rel)
        if rel.startswith('..') or not os.path.isfile(full):
            return self.json({'error': 'Nicht gefunden'}, 404)
        with open(full, 'rb') as f:
            self.send(200, f.read(), TYPES.get(os.path.splitext(full)[1], 'application/octet-stream'))


def main():
    global APP
    APP = App()
    APP.start()
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    server.daemon_threads = True
    log(f'Luftbilder: Port {PORT}, Zoom {MIN_ZOOM}–{MAX_ZOOM}, {len(APP.built)} Luftbilder umgewandelt')
    server.serve_forever()


if __name__ == '__main__':
    main()
