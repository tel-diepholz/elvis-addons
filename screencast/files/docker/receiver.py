#!/usr/bin/env python3
"""
Empfänger der Bildschirmübertragung für ELVIS.

Je Empfänger (z. B. „Leinwand“) gibt es einen Pfad in MediaMTX, den zwei Wege füllen können:
  - AirPlay: UxPlay entschlüsselt die Bildschirmsynchronisierung von iPhone/iPad/Mac und reicht das H.264 per RTP
    (-vrtp, ohne Umkodieren) an eine kleine GStreamer-Brücke weiter, die es per RTSP an MediaMTX schickt.
  - Browser: Die Freigabeseite (HTTPS, getDisplayMedia) sendet per WHIP; dieser Dienst reicht WHIP an MediaMTX auf
    localhost durch. Die Medien selbst laufen per WebRTC direkt zu MediaMTX.
Wer zuletzt sendet, ist zu sehen (overridePublisher in MediaMTX). Den Zustand je Pfad liefert die MediaMTX-API.

Einstellungen kommen als Umgebungsvariablen aus dem Addon:
  RECEIVERS       kommagetrennte Namen der Empfänger
  AIRPLAY         true = AirPlay-Empfänger starten
  BROWSER_SHARE   true = Freigabeseite anbieten
  AUDIO           true = Ton übertragen (Opus)
  TRANSCODE       off | cpu | vaapi
  BITRATE         kbit/s beim Umkodieren
  RESOLUTION      720 | 1080 (bei Apple-Geräten angefragte Auflösung)
  FPS             höchste Bildrate für AirPlay
  HOST_ADDRESS    Adresse des Docker-Hosts (für Freigabe-Adresse und Zertifikat)
  SHARE_PORT      HTTPS-Port der Freigabeseite
  STATUS_PORT     Port für den Status (JSON unter /status.json) – ELVIS fragt ihn ab
  AIRPLAY_PORT    erster AirPlay-Port; je Empfänger drei Ports (TCP und UDP)
  RTSP_PORT, WEBRTC_PORT, API_PORT  Ports von MediaMTX (RTSP und API nur auf localhost)
"""
import hashlib
import http.client
import http.server
import json
import os
import re
import signal
import ssl
import subprocess
import threading
import time
import unicodedata
import urllib.parse
import urllib.request


def env_bool(name: str, default: str = "true") -> bool:
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes")


AIRPLAY = env_bool("AIRPLAY")
BROWSER_SHARE = env_bool("BROWSER_SHARE")
AUDIO = env_bool("AUDIO")
TRANSCODE = os.environ.get("TRANSCODE", "off")
BITRATE = int(os.environ.get("BITRATE", "6000"))
HEIGHT = 720 if os.environ.get("RESOLUTION", "1080") == "720" else 1080
WIDTH = HEIGHT * 16 // 9
FPS = int(os.environ.get("FPS", "30"))
HOST_ADDRESS = os.environ.get("HOST_ADDRESS", "").strip()
SHARE_PORT = int(os.environ.get("SHARE_PORT", "8443"))
STATUS_PORT = int(os.environ.get("STATUS_PORT", "8898"))
AIRPLAY_PORT = int(os.environ.get("AIRPLAY_PORT", "7100"))
RTSP = f"rtsp://127.0.0.1:{os.environ.get('RTSP_PORT', '8564')}"
WEBRTC_PORT = int(os.environ.get("WEBRTC_PORT", "8899"))
API = f"http://127.0.0.1:{os.environ.get('API_PORT', '9987')}"
DATA = os.environ.get("DATA_DIR", "/data")
SHARE_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "share.html")
# interne RTP-Ports zwischen UxPlay und Brücke (nur 127.0.0.1)
RTP_BASE = int(os.environ.get("RTP_BASE", "17100"))
GOP = 60


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def sender_name(name: str, model: str) -> str:
    """Anzeigename des AirPlay-Geräts. Verwaltete Geräte heißen oft wie ihre Seriennummer (z. B. „GYFHM6675F“) –
    dann den Gerätetyp davorsetzen: „iPhone GYFHM6675F“."""
    name, model = name.strip(), model.strip()
    kind = next((k for k in ("iPhone", "iPad", "Mac", "AppleTV") if model.startswith(k)), "")
    if not name:
        return kind or "AirPlay-Gerät"
    if kind and re.fullmatch(r"[A-Z0-9]{8,14}", name):
        return f"{kind} {name}"
    return name


class TlsServer(http.server.ThreadingHTTPServer):
    """HTTPS-Server, der das Zertifikat neu lädt, sobald ELVIS es erneuert hat (Datei key.pem geändert).

    Browser, die der CA nicht vertrauen, brechen den TLS-Handshake ab (certificate unknown) – das ist erwartet und
    gehört nicht als Traceback ins Log."""

    def __init__(self, address, handler) -> None:
        super().__init__(address, handler)
        self.ctx: ssl.SSLContext | None = None
        self.stamp: tuple | None = None
        self.ctx_lock = threading.Lock()
        self.context()

    def context(self) -> ssl.SSLContext:
        cert, key, source = certificate()
        stamp = (cert, os.stat(cert).st_mtime_ns, os.stat(key).st_mtime_ns)
        with self.ctx_lock:
            if stamp != self.stamp or not self.ctx:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(cert, key)
                self.ctx, self.stamp = ctx, stamp
                log(f"Freigabeseite: Zertifikat {source}")
            return self.ctx

    def get_request(self):
        sock, addr = self.socket.accept()
        try:
            ctx = self.context()
        except (OSError, ssl.SSLError) as err:  # ELVIS schreibt gerade neue Dateien – altes Zertifikat behalten
            log(f"Zertifikat nicht lesbar ({err}) – nutze das bisherige")
            ctx = self.ctx
        # Handshake erst im Thread der Anfrage – ein langsamer Client hält die anderen nicht auf
        return ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

    def handle_error(self, request, client_address) -> None:
        import sys

        err = sys.exc_info()[1]
        if isinstance(err, (ssl.SSLError, ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def slug(name: str) -> str:
    """Empfängername → Pfad für MediaMTX, z. B. „Leinwand Süd“ → „leinwand-sud“."""
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return s[:40] or "empfaenger"


def parse_receivers(raw: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for name in (n.strip() for n in raw.split(",")):
        if not name or any(n == name for n, _ in out):
            continue
        path = slug(name)
        while any(p == path for _, p in out):
            path += "-2"
        out.append((name[:60], path))
    return out or [("Leinwand", "leinwand")]


def share_url(path: str) -> str:
    return f"https://{HOST_ADDRESS or 'localhost'}:{SHARE_PORT}/?r={urllib.parse.quote(path)}"


# --- AirPlay ---------------------------------------------------------------------------------------------------------

H264_CAPS = "video/x-h264,profile=constrained-baseline"


def transcode_chain() -> str:
    """Nur bei TRANSCODE != off: dekodieren und als H.264 Constrained Baseline neu kodieren (wie im NDI-Gateway)."""
    if TRANSCODE == "vaapi":
        enc = f"vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vah264enc bitrate={BITRATE} key-int-max={GOP} b-frames=0 target-usage=6 ! {H264_CAPS}"
    else:
        enc = f"video/x-raw,format=I420 ! x264enc bitrate={BITRATE} key-int-max={GOP} bframes=0 tune=zerolatency speed-preset=veryfast ! {H264_CAPS}"
    return f"avdec_h264 ! videoconvert ! {enc} ! h264parse config-interval=-1 ! "


def bridge_pipeline(path: str, vport: int, aport: int) -> list[str]:
    """RTP von UxPlay (localhost) → RTSP an MediaMTX. Bild wird ohne Umkodieren durchgereicht."""
    video = (
        f'udpsrc address=127.0.0.1 port={vport} caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! '
        "rtph264depay ! h264parse config-interval=-1 ! "
        f"{transcode_chain() if TRANSCODE in ('cpu', 'vaapi') else ''}"
        "queue ! s. "
    )
    # Stille unterlegen: so steht das Tonformat sofort fest, auch wenn das Gerät gerade keinen Ton schickt
    audio = (
        "audiotestsrc is-live=true wave=silence ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! m. "
        f'udpsrc address=127.0.0.1 port={aport} caps="application/x-rtp,media=audio,clock-rate=44100,encoding-name=L16,encoding-params=2,channels=2,payload=97" ! '
        "rtpL16depay ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! queue max-size-time=200000000 leaky=downstream ! m. "
        "audiomixer name=m latency=40000000 ! audioconvert ! opusenc bitrate=128000 frame-size=10 ! s. "
        if AUDIO
        else ""
    )
    desc = f"rtspclientsink name=s location={RTSP}/{path} protocols=tcp latency=0 {video}{audio}"
    return ["gst-launch-1.0", "-e", *split_args(desc)]


def split_args(desc: str) -> list[str]:
    """gst-launch nimmt die Beschreibung als Argumente; Anführungszeichen (Caps) zusammenhalten."""
    out, cur, quoted = [], "", False
    for ch in desc:
        if ch == '"':
            quoted = not quoted
            cur += ch
        elif ch == " " and not quoted:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def mac_for(path: str) -> str:
    """Feste Geräte-ID je Empfänger (lokal verwaltete MAC) – Apple-Geräte erkennen den Empfänger so wieder."""
    h = hashlib.sha256(f"elvis-screencast-{path}".encode()).digest()
    return ":".join(f"{b:02x}" for b in bytes([(h[0] | 0x02) & 0xFE]) + h[1:6])


class AirPlay:
    """Eine UxPlay-Instanz je Empfänger; die Brücke zu MediaMTX läuft nur während einer Verbindung."""

    def __init__(self, index: int, name: str, path: str):
        self.name = name
        self.path = path
        self.port = AIRPLAY_PORT + 3 * index
        self.vport = RTP_BASE + 4 * index
        self.aport = self.vport + 2
        self.proc: subprocess.Popen | None = None
        self.bridge: subprocess.Popen | None = None
        self.connected = False
        self.sender: str | None = None
        self.problem = ""
        self.restarts = 0
        self.next_start = 0.0
        self.bridge_restarts = 0
        self.bridge_next = 0.0
        self.lock = threading.Lock()

    def command(self) -> list[str]:
        os.makedirs(os.path.join(DATA, "keys"), exist_ok=True)
        cmd = [
            "uxplay", "-n", self.name, "-nh", "-p", str(self.port), "-m", mac_for(self.path),
            "-key", os.path.join(DATA, "keys", f"{self.path}.pem"),
            # neues Gerät löst das laufende ab (offener Zugriff, wie bei der Browser-Freigabe)
            "-nohold",
            "-s", f"{WIDTH}x{HEIGHT}", "-fps", str(FPS),
            # kein Abgleich von Ton und Bild auf dem Empfänger: geringste Verzögerung
            "-vsync", "no",
            "-vrtp", f"config-interval=1 pt=96 ! udpsink host=127.0.0.1 port={self.vport} sync=false",
            "-d",
        ]
        if AUDIO:
            cmd += ["-artp", f"pt=97 ! udpsink host=127.0.0.1 port={self.aport} sync=false"]
        else:
            cmd += ["-a"]
        return cmd

    def start(self) -> None:
        log(f"AirPlay „{self.name}“ auf Port {self.port} → /{self.path}")
        self.proc = subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()

    def _read(self, proc: subprocess.Popen) -> None:
        assert proc.stdout
        for raw in proc.stdout:
            line = raw.strip()
            if not line:
                continue
            m = re.search(r"connection request from (.*) \((.*?)\) with deviceID", line)
            if m:
                with self.lock:
                    self.connected = True
                    self.sender = sender_name(m.group(1), m.group(2))
                    self.bridge_restarts = 0
                    self.bridge_next = 0.0
                log(f"AirPlay „{self.name}“: Verbindung von {self.sender} ({m.group(2).strip()})")
                continue
            if re.search(r"Open connections: 0\b", line):
                with self.lock:
                    was = self.connected
                    self.connected = False
                    self.sender = None
                if was:
                    log(f"AirPlay „{self.name}“: Verbindung beendet")
                    self.stop_bridge()
                continue
            if "Initialized server socket" in line:
                self.problem = ""
                self.restarts = 0
            elif "another instance" in line or "failed to start" in line.lower() or "No DNS-SD Server" in line:
                self.problem = f"AirPlay „{self.name}“: {line[:200]}"
                log(self.problem)
            elif line.startswith("***") or "ERROR" in line:
                log(f"AirPlay „{self.name}“: {line[:300]}")

    def check(self, owner: str | None) -> None:
        """owner: Art der Quelle, die den Pfad in MediaMTX gerade hält (rtspSession, webRTCSession …) oder None."""
        now = time.time()
        if self.proc and self.proc.poll() is not None:
            code = self.proc.returncode
            self.proc = None
            with self.lock:
                self.connected = False
                self.sender = None
            self.stop_bridge()
            self.restarts += 1
            self.next_start = now + min(60, 5 * self.restarts)
            self.problem = self.problem or f"AirPlay „{self.name}“ beendet (Code {code}) – starte neu"
            log(self.problem)
        if not self.proc and now >= self.next_start:
            self.start()

        if self.bridge and self.bridge.poll() is not None:
            log(f"Brücke /{self.path} beendet (Code {self.bridge.returncode})")
            self.bridge = None
            self.bridge_restarts += 1
            self.bridge_next = now + min(30, 2 * self.bridge_restarts)
        # Während einer AirPlay-Verbindung senden – außer eine Browser-Freigabe hat den Empfänger übernommen
        if self.connected and not self.bridge and now >= self.bridge_next and owner in (None, "rtspSession"):
            log(f"Brücke /{self.path} startet")
            self.bridge = subprocess.Popen(
                bridge_pipeline(self.path, self.vport, self.aport), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
            )
            threading.Thread(target=self._read_bridge, args=(self.bridge,), daemon=True).start()

    def _read_bridge(self, proc: subprocess.Popen) -> None:
        """Fehler und Warnungen von gst-launch ins Log – sonst bleibt unsichtbar, warum kein Bild ankommt."""
        assert proc.stdout
        for raw in proc.stdout:
            line = raw.strip()
            if line.startswith(("ERROR", "WARNING")) or "Additional debug info" in line or "error" in line.lower():
                log(f"Brücke /{self.path}: {line[:300]}")

    def stop_bridge(self) -> None:
        b, self.bridge = self.bridge, None
        if b and b.poll() is None:
            b.terminate()
            try:
                b.wait(3)
            except subprocess.TimeoutExpired:
                b.kill()

    def stop(self) -> None:
        self.stop_bridge()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def start_mdns() -> None:
    """AirPlay meldet sich per mDNS über Avahi (D-Bus) an – beides im Container starten (wie im NDI-Gateway)."""
    os.makedirs("/run/dbus", exist_ok=True)
    if not os.path.exists("/run/dbus/system_bus_socket"):
        subprocess.Popen(["dbus-daemon", "--system", "--nofork", "--nopidfile"])
        for _ in range(50):
            if os.path.exists("/run/dbus/system_bus_socket"):
                break
            time.sleep(0.1)
    subprocess.Popen(["avahi-daemon", "--no-drop-root", "--no-chroot", "--no-rlimits"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)


# --- Zustand ---------------------------------------------------------------------------------------------------------


class State:
    def __init__(self, receivers: list[tuple[str, str]]):
        self.receivers = receivers
        self.airplay: dict[str, AirPlay] = {}
        # Name des Rechners, der zuletzt per Browser auf den Pfad gesendet hat
        self.browser_sender: dict[str, str] = {}
        # Pfad → Art der Quelle in MediaMTX (rtspSession = AirPlay-Brücke, webRTCSession = Browser)
        self.owners: dict[str, str] = {}
        self.api_ok = False
        self.lock = threading.Lock()

    def poll_mediamtx(self) -> None:
        try:
            with urllib.request.urlopen(f"{API}/v3/paths/list?itemsPerPage=1000", timeout=2) as res:
                items = json.load(res).get("items") or []
            owners = {i["name"]: (i.get("source") or {}).get("type", "") for i in items if i.get("ready") or i.get("available")}
            ok = True
        except Exception:  # noqa: BLE001 – MediaMTX startet noch o. Ä.
            owners, ok = {}, False
        with self.lock:
            self.owners, self.api_ok = owners, ok
            for path in list(self.browser_sender):
                if owners.get(path) != "webRTCSession":
                    del self.browser_sender[path]

    def status(self) -> dict:
        with self.lock:
            owners = dict(self.owners)
            browser = dict(self.browser_sender)
            api_ok = self.api_ok
        streams = []
        problems = [a.problem for a in self.airplay.values() if a.problem]
        for name, path in self.receivers:
            owner = owners.get(path)
            ap = self.airplay.get(path)
            via, sender, state = None, None, "idle"
            if owner:
                state = "running"
                if owner == "webRTCSession":
                    via, sender = "browser", browser.get(path) or "Browser"
                else:
                    via, sender = "airplay", (ap.sender if ap else None) or "AirPlay-Gerät"
            elif ap and ap.connected:
                state, via, sender = "starting", "airplay", ap.sender
            connect = {}
            if AIRPLAY:
                connect["airplay"] = name
            if BROWSER_SHARE:
                connect["shareUrl"] = share_url(path)
            streams.append({"name": name, "path": path, "state": state, "error": "", "sender": sender, "via": via, "connect": connect})
        if not api_ok:
            problems.insert(0, "MediaMTX antwortet nicht")
        return {
            "updatedAt": time.time(),
            "encoder": "durchgereicht" if TRANSCODE == "off" else TRANSCODE,
            "resolution": f"{WIDTH}x{HEIGHT}",
            "problem": "; ".join(problems),
            "sources": [],
            "streams": streams,
        }


STATE: State


class StatusHandler(http.server.BaseHTTPRequestHandler):
    """Liefert nur den Status aus – keine Steuerung über das Netz."""

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?")[0] not in ("/", "/status.json"):
            self.send_error(404)
            return
        body = json.dumps(STATE.status()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


# --- Freigabeseite (HTTPS) und WHIP-Proxy -----------------------------------------------------------------------------

WHIP_PATH = re.compile(r"^/([a-z0-9-]+)/whip(/[A-Za-z0-9_-]+)?$")


class ShareHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        if path == "/":
            config = {
                "receivers": [{"name": n, "path": p} for n, p in STATE.receivers],
                "audio": AUDIO,
                "airplay": AIRPLAY,
            }
            with open(SHARE_HTML, "rb") as f:
                html = f.read().replace(b"/*CONFIG*/null", json.dumps(config).encode())
            self._send(200, html, "text/html; charset=utf-8", {"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"})
        elif path == "/status.json":
            status = STATE.status()
            body = json.dumps([{k: s[k] for k in ("name", "path", "state", "sender", "via")} for s in status["streams"]]).encode()
            self._send(200, body, "application/json")
        else:
            self._send(404, b"Nicht gefunden", "text/plain; charset=utf-8")

    def _proxy(self) -> None:
        url = urllib.parse.urlsplit(self.path)
        m = WHIP_PATH.match(url.path)
        if not BROWSER_SHARE or not m or m.group(1) not in {p for _, p in STATE.receivers}:
            self._send(404, b"Unbekannter Empfaenger", "text/plain")
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() in ("content-type", "if-match", "accept")}
        conn = http.client.HTTPConnection("127.0.0.1", WEBRTC_PORT, timeout=10)
        try:
            conn.request(self.command, url.path, body=body, headers=headers)
            res = conn.getresponse()
            data = res.read()
        except OSError as err:
            self._send(502, f"MediaMTX nicht erreichbar: {err}".encode(), "text/plain; charset=utf-8")
            return
        finally:
            conn.close()
        extra = {k: v for k, v in res.getheaders() if k.lower() in ("location", "etag", "link", "accept-patch")}
        if self.command == "POST" and res.status == 201:
            name = (urllib.parse.parse_qs(url.query).get("name") or [""])[0].strip()[:60]
            with STATE.lock:
                STATE.browser_sender[m.group(1)] = name or "Browser"
            log(f"Browser-Freigabe auf /{m.group(1)} von {name or 'unbekannt'} ({self.client_address[0]})")
        self._send(res.status, data, res.getheader("Content-Type") or "text/plain", extra)

    do_POST = _proxy  # noqa: N815
    do_PATCH = _proxy  # noqa: N815
    do_DELETE = _proxy  # noqa: N815

    def log_message(self, *_args) -> None:
        pass


ELVIS_TLS = os.path.join(DATA, "elvis-tls")


def certificate() -> tuple[str, str, str]:
    """Zertifikat der Freigabeseite: bevorzugt das von ELVIS (aus der ELVIS-CA, manifest „tls“), sonst selbstsigniert.
    Browser erlauben Bildschirmfreigabe nur über HTTPS."""
    cert, key = os.path.join(ELVIS_TLS, "cert.pem"), os.path.join(ELVIS_TLS, "key.pem")
    if os.path.exists(cert) and os.path.exists(key):
        return cert, key, "aus der ELVIS-CA"
    return (*self_signed(), "selbstsigniert (ELVIS hat keins geliefert)")


def self_signed() -> tuple[str, str]:
    """Notlösung für ältere ELVIS-Versionen ohne „tls“ im Manifest: Browser warnen dann einmal."""
    folder = os.path.join(DATA, "tls")
    cert, key, marker = (os.path.join(folder, f) for f in ("cert.pem", "key.pem", "subject"))
    subject = HOST_ADDRESS or "localhost"
    try:
        with open(marker) as f:
            if f.read().strip() == subject and os.path.exists(cert) and os.path.exists(key):
                return cert, key
    except OSError:
        pass
    os.makedirs(folder, exist_ok=True)
    san = f"IP:{subject}" if re.fullmatch(r"[0-9.]+|[0-9a-fA-F:]+", subject) else f"DNS:{subject}"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
         "-subj", f"/CN={subject}/O=ELVIS Bildschirmübertragung", "-addext", f"subjectAltName={san},DNS:localhost",
         "-keyout", key, "-out", cert],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    with open(marker, "w") as f:
        f.write(subject)
    log(f"Selbstsigniertes Zertifikat für {subject} erzeugt")
    return cert, key


def serve() -> None:
    status = http.server.ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    threading.Thread(target=status.serve_forever, daemon=True).start()
    log(f"Status unter :{STATUS_PORT}/status.json")
    if BROWSER_SHARE:
        share = TlsServer(("0.0.0.0", SHARE_PORT), ShareHandler)
        threading.Thread(target=share.serve_forever, daemon=True).start()
        log(f"Freigabeseite unter https://{HOST_ADDRESS or '<host>'}:{SHARE_PORT}/")


def main() -> None:
    global STATE
    STATE = State(parse_receivers(os.environ.get("RECEIVERS", "Leinwand")))
    log(f"Empfänger: {', '.join(f'{n} (/{p})' for n, p in STATE.receivers)}")
    serve()
    if AIRPLAY:
        start_mdns()
        for i, (name, path) in enumerate(STATE.receivers):
            STATE.airplay[path] = AirPlay(i, name, path)

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    while not stop.is_set():
        STATE.poll_mediamtx()
        with STATE.lock:
            owners = dict(STATE.owners)
        for ap in STATE.airplay.values():
            ap.check(owners.get(ap.path))
        stop.wait(1)
    for ap in STATE.airplay.values():
        ap.stop()


if __name__ == "__main__":
    main()
