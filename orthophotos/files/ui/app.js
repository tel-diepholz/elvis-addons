// Auswahl der Luftbilder: Abdeckung auf der Karte, Klick (bzw. Umschalt + Rechteck) wählt aus oder ab.
// Läuft hinter dem Addon-Proxy von ELVIS (/api/addons/<id>/ui/) – eigene Pfade daher immer relativ.
'use strict';

const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const BUSY = new Set(['queued', 'downloading', 'converting']);
const STATUS_TEXT = { none: 'verfügbar', queued: 'wartet', downloading: 'wird geladen', converting: 'wird umgewandelt', ready: 'umgewandelt', error: 'Fehler' };
const fmtBytes = (b) => (b >= 1e12 ? `${(b / 1e12).toFixed(1)} TB` : b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : `${Math.round(b / 1e6)} MB`);

async function api(path, body) {
  const res = await fetch(path, body ? { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) } : {});
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `HTTP ${res.status}`);
  return res.json();
}

// --- Karte ---

const map = L.map('map', { boxZoom: false, minZoom: 5, maxZoom: 20 }).setView([52.7, 9.2], 8);
const renderer = L.canvas({ padding: 0.3 });
const coverage = L.layerGroup().addTo(map);
let baseLayer = null;
// v: wechselt mit jeder Änderung, sonst zeigt der Browser noch die leere Kachel aus seinem Cache
const overlay = L.tileLayer('tiles/{z}/{x}/{y}.png?v={v}', { maxZoom: 20, zIndex: 5, v: 0 });

// Grundkarte aus den Kartenquellen von ELVIS (gleicher Ursprung über den Proxy)
async function loadBaseMaps() {
  const select = $('base');
  let sources = [];
  try {
    sources = (await api('/api/map/sources')).filter((s) => !s.id.startsWith('orthophotos-') && s.variant !== 'print');
  } catch {
    /* Seite direkt am Addon geöffnet – ohne Grundkarte */
  }
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  sources.sort((a, b) => Number((b.variant === 'dark') === dark) - Number((a.variant === 'dark') === dark));
  select.innerHTML = sources.map((s) => `<option value="${s.id}">${s.name}</option>`).join('') + '<option value="">ohne</option>';
  const apply = () => {
    if (baseLayer) map.removeLayer(baseLayer);
    const s = sources.find((x) => x.id === select.value);
    baseLayer = s ? L.tileLayer(`/api/map/tiles/${s.id}/{z}/{x}/{y}`, { maxZoom: 20, maxNativeZoom: s.maxZoom, attribution: s.attribution, zIndex: 1 }).addTo(map) : null;
  };
  select.onchange = apply;
  apply();
}

$('overlay').onchange = (e) => (e.target.checked ? overlay.addTo(map) : map.removeLayer(overlay));
overlay.addTo(map);

// --- Abdeckung und Auswahl ---

const pending = new Map(); // id → 'add' | 'remove'
let items = new Map(); // id → { bbox, status, date, built }
let mode = 'grid';
let status = null;

function isSelected(it) {
  return it.status !== 'none';
}
function outdated(it) {
  return it.built && it.built < it.date;
}

function styleFor(it) {
  const p = pending.get(it.id);
  if (p === 'add') return { color: css('--add'), fillColor: css('--add'), fillOpacity: 0.35, weight: 2 };
  if (p === 'remove') return { color: css('--error'), fillOpacity: 0, weight: 2, dashArray: '4 3' };
  if (it.status === 'error') return { color: css('--error'), fillColor: css('--error'), fillOpacity: 0.3, weight: 2 };
  if (BUSY.has(it.status)) return { color: css('--busy'), fillColor: css('--busy'), fillOpacity: 0.35, weight: 2 };
  if (it.status === 'ready') return { color: outdated(it) ? css('--outdated') : css('--ready'), fillColor: css('--ready'), fillOpacity: $('overlay').checked ? 0.08 : 0.3, weight: outdated(it) ? 2.5 : 1.5 };
  return { color: css('--none'), fillOpacity: 0.02, weight: 0.7 };
}

function tooltip(it) {
  let s = `<b>${it.id}</b><br>Aufnahme ${it.date || 'unbekannt'}<br>${STATUS_TEXT[it.status]}`;
  if (outdated(it)) s += ` (Fassung ${it.built}, neuere verfügbar)`;
  if (it.error) s += `<br>${it.error}`;
  return s;
}

function toggle(it, force) {
  const want = force ?? (pending.has(it.id) ? null : isSelected(it) && !outdated(it) ? 'remove' : 'add');
  if (want === null || (want === 'add' && isSelected(it) && !outdated(it)) || (want === 'remove' && !isSelected(it))) pending.delete(it.id);
  else pending.set(it.id, want);
}

function render() {
  coverage.clearLayers();
  if (mode === 'grid') {
    for (const [w, s, e, n, total, busy, ready] of items.values()) {
      const color = ready ? css('--ready') : busy ? css('--busy') : css('--none');
      L.rectangle([[s, w], [n, e]], { renderer, color, weight: 0.7, fillColor: color, fillOpacity: ready || busy ? 0.35 : 0.08 })
        .bindTooltip(`${total} Luftbilder${ready ? `, ${ready} umgewandelt` : ''}${busy ? `, ${busy} in Arbeit` : ''}`, { sticky: true })
        .on('click', () => map.fitBounds([[s, w], [n, e]]))
        .addTo(coverage);
    }
  } else {
    for (const it of items.values()) {
      const [w, s, e, n] = it.bbox;
      L.rectangle([[s, w], [n, e]], { renderer, ...styleFor(it) })
        .bindTooltip(() => tooltip(it), { sticky: true })
        .on('click', () => {
          toggle(it);
          render();
          updateActions();
        })
        .addTo(coverage);
    }
  }
}

let loadSeq = 0;
async function loadImages() {
  const b = map.getBounds();
  const seq = ++loadSeq;
  const res = await api(`api/images?bbox=${[b.getWest(), b.getSouth(), b.getEast(), b.getNorth()].map((v) => v.toFixed(5)).join(',')}&zoom=${Math.floor(map.getZoom())}`);
  if (seq !== loadSeq) return;
  mode = res.mode;
  items = new Map(
    res.mode === 'grid'
      ? res.items.map((r, i) => [i, r])
      : res.items.map(([id, w, s, e, n, st, date, built, error]) => [id, { id, bbox: [w, s, e, n], status: st, date, built, error }]),
  );
  $('hint').textContent =
    res.mode === 'grid'
      ? status?.index.total
        ? 'Zum Auswählen näher heranzoomen (oder auf eine Zelle klicken).'
        : ''
      : res.truncated
        ? 'Zu viele Luftbilder im Ausschnitt – bitte näher heranzoomen.'
        : 'Klick wählt ein Luftbild aus oder ab. Umschalt + Ziehen wählt mehrere aus, Umschalt + Alt + Ziehen wählt ab.';
  render();
}
map.on('moveend', () => void loadImages().catch(showError));
$('overlay').addEventListener('change', render);

// Umschalt + Ziehen: Rechteck aufziehen
let box = null;
map.getContainer().addEventListener(
  'mousedown',
  (ev) => {
    if (!ev.shiftKey || ev.button !== 0 || mode !== 'detail') return;
    ev.preventDefault();
    ev.stopPropagation();
    map.dragging.disable();
    const start = map.mouseEventToLatLng(ev);
    box = { start, remove: ev.altKey, rect: L.rectangle([start, start], { className: 'select-box', interactive: false, weight: 0 }).addTo(map) };
  },
  true,
);
document.addEventListener('mousemove', (ev) => box && box.rect.setBounds([box.start, map.mouseEventToLatLng(ev)]));
document.addEventListener('mouseup', () => {
  if (!box) return;
  const bounds = box.rect.getBounds();
  map.removeLayer(box.rect);
  map.dragging.enable();
  for (const it of items.values()) {
    const [w, s, e, n] = it.bbox;
    if (bounds.intersects([[s, w], [n, e]])) toggle(it, box.remove ? 'remove' : 'add');
  }
  box = null;
  render();
  updateActions();
});

// Fläche einer Bbox in km² (genügt für die Abschätzung)
function area(bbox) {
  if (!bbox) return 0;
  const [w, s, e, n] = bbox;
  return (e - w) * 111.32 * Math.cos((((s + n) / 2) * Math.PI) / 180) * (n - s) * 110.57;
}

function updateActions() {
  const add = [...pending.values()].filter((v) => v === 'add').length;
  const remove = pending.size - add;
  $('actions').hidden = pending.size === 0;
  const mbPerKm2 = status?.sources[0]?.mb_per_km2 ?? 5;
  const km2 = [...pending].filter(([, v]) => v === 'add').reduce((sum, [id]) => sum + area(items.get(id)?.bbox), 0);
  const parts = [];
  if (add) parts.push(`${add} zum Umwandeln gewählt (${Math.round(km2)} km², Download ca. ${fmtBytes(km2 * mbPerKm2 * 1e6)})`);
  if (remove) parts.push(`${remove} zum Löschen gewählt`);
  $('pending').textContent = parts.join(' · ');
}

$('discard').onclick = () => {
  pending.clear();
  render();
  updateActions();
};

$('apply').onclick = async () => {
  const add = [...pending].filter(([, v]) => v === 'add').map(([k]) => k);
  const remove = [...pending].filter(([, v]) => v === 'remove').map(([k]) => k);
  const readyRemoved = remove.filter((id) => items.get(id)?.status === 'ready').length;
  if (readyRemoved && !confirm(`${readyRemoved} umgewandelte Luftbilder löschen? Sie verschwinden aus dem Kartenstil und müssten neu geladen werden.`)) return;
  $('apply').disabled = true;
  try {
    await api('api/selection', { add, remove });
    pending.clear();
    updateActions();
    await Promise.all([loadStatus(), loadImages()]);
  } catch (e) {
    showError(e);
  } finally {
    $('apply').disabled = false;
  }
};

// --- Status ---

function showError(e) {
  $('hint').textContent = `Fehler: ${e.message}`;
}

let lastKey = '';
let fitted = false;
async function loadStatus() {
  status = await api('api/status');
  const { index, counts, current } = status;
  const src = status.sources.map((s) => `${s.name} (${s.agency}, ${s.product}, ${s.license})`).join(', ');
  if (index.state === 'loading') $('index').textContent = `Index wird geladen: ${index.message ?? ''} ${index.percent ?? 0} %`;
  else if (index.state === 'error') $('index').textContent = `Index-Fehler: ${index.error}`;
  else $('index').textContent = index.total ? `${index.total.toLocaleString('de-DE')} Luftbilder · ${src} · Stand ${(index.loadedAt ?? '').slice(0, 10)}` : 'Noch kein Index geladen';
  $('refresh').disabled = index.state === 'loading';

  const busy = counts.queued + counts.downloading + counts.converting;
  $('counts').textContent = `${counts.ready} umgewandelt${busy ? ` · ${busy} in Arbeit` : ''}${counts.error ? ` · ${counts.error} Fehler` : ''}`;
  $('storage').textContent = `${fmtBytes(status.bytes)} belegt · ${fmtBytes(status.free)} frei`;
  $('outdated').hidden = !status.outdated;
  $('outdated').textContent = `${status.outdated} neuere Fassungen laden`;
  $('retry').hidden = !counts.error;
  $('legacy').hidden = !status.legacyBytes;
  $('legacy').textContent = `Alte Daten aus Version 1 löschen (${fmtBytes(status.legacyBytes || 0)})`;

  $('current').hidden = !current;
  if (current) {
    const text = current.stage === 'downloading' ? 'wird geladen' : 'wird umgewandelt';
    $('current').querySelector('.progress-text').textContent = `${current.id} ${text} – ${current.percent} %${counts.queued ? ` · ${counts.queued} warten` : ''}`;
    $('current').querySelector('.progress-fill').style.width = `${current.percent}%`;
  }

  if (!fitted && (status.builtBounds || status.bounds)) {
    fitted = true;
    const [w, s, e, n] = status.builtBounds || status.bounds;
    map.fitBounds([[s, w], [n, e]], { maxZoom: 13 });
  }
  // Bei Änderungen (fertig, Fehler, Index geladen) die Abdeckung neu laden
  const key = JSON.stringify([counts, index.total, status.outdated]);
  if (key !== lastKey) {
    lastKey = key;
    overlay.options.minZoom = status.zoom.min;
    overlay.options.v = Date.now();
    overlay.redraw();
    await loadImages();
  }
}

$('refresh').onclick = () => api('api/index/refresh', {}).then(loadStatus).catch(showError);
$('retry').onclick = () => api('api/retry', { all: true }).then(loadStatus).catch(showError);
$('outdated').onclick = () => api('api/selection', { outdated: true }).then(loadStatus).catch(showError);
$('legacy').onclick = () => {
  if (!confirm('Kacheln und Downloads der alten Version (ganze Bundesländer) löschen?')) return;
  api('api/legacy/delete', {}).then(loadStatus).catch(showError);
};

loadBaseMaps();
const poll = () => loadStatus().catch(showError).finally(() => setTimeout(poll, 2000));
poll();
