#!/usr/bin/env python3
"""
NDI-Gateway für ELVIS: findet NDI-Quellen im Netz und gibt jede als H.264-Strom an MediaMTX weiter
(RTSP), das sie per WebRTC an Browser verteilt.

Einstellungen kommen als Umgebungsvariablen aus dem Addon:
  ENCODER      cpu | vaapi | nvenc
  RESOLUTION   720 | 1080
  BITRATE      kbit/s
  FPS          Bilder pro Sekunde
  SOURCES      kommagetrennte Filter (Teil des NDI-Namens, Groß-/Kleinschreibung egal); leer = alle
  MAX_STREAMS  Höchstzahl gleichzeitiger Ströme
  AUDIO        true = Ton mitsenden (Opus)
  DISCOVERY    optional: NDI Discovery Server (IP[:Port]) statt mDNS
  TRANSPORT    tcp = Empfang über TCP (zuverlässig durch NAT/Firewall/Docker Desktop), udp = NDI-Standard (Reliable UDP)
  RTSP_PORT    Port von MediaMTX (RTSP)
  STATUS_PORT  Port für den Status (nur lesend, JSON unter /status.json) – ELVIS fragt ihn ab
  NDI_RUNTIME_DIR_V6  Ordner mit libndi.so.6 (lädt das Addon nach Zustimmung zur NDI-Lizenz)
"""
import http.server
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import unicodedata

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

ENCODER = os.environ.get("ENCODER", "cpu")
HEIGHT = 1080 if os.environ.get("RESOLUTION", "720") == "1080" else 720
WIDTH = HEIGHT * 16 // 9
BITRATE = int(os.environ.get("BITRATE", "4000"))
FPS = int(os.environ.get("FPS", "25"))
FILTERS = [f.strip().lower() for f in os.environ.get("SOURCES", "").split(",") if f.strip()]
MAX_STREAMS = int(os.environ.get("MAX_STREAMS", "4"))
AUDIO = os.environ.get("AUDIO", "true").lower() in ("1", "true", "yes")
DISCOVERY = os.environ.get("DISCOVERY", "").strip()
TRANSPORT = os.environ.get("TRANSPORT", "tcp")
RTSP = f"rtsp://127.0.0.1:{os.environ.get('RTSP_PORT', '8554')}"
STATUS_FILE = os.environ.get("STATUS_FILE", "/data/status.json")
NDI_DIR = os.environ.get("NDI_RUNTIME_DIR_V6", "/data/ndi/lib")
# das GStreamer-Plugin lädt libndi.so.6 aus diesem Ordner
os.environ["NDI_RUNTIME_DIR_V6"] = NDI_DIR

STATUS_PORT = int(os.environ.get("STATUS_PORT", "8890"))

GOP = FPS * 2  # Schlüsselbild alle 2 s: schneller Einstieg für neue Zuschauer


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def slug(name: str) -> str:
    """NDI-Name → Pfad für MediaMTX, z. B. „STUDIO-PC (Kamera 1)“ → „studio-pc-kamera-1“."""
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return s[:60] or "ndi"


# Browser spielen per WebRTC verlässlich nur H.264 „Constrained Baseline“ mit 4:2:0 ab
H264_CAPS = "video/x-h264,profile=constrained-baseline"


def encoder_chain() -> str:
    """Encoder je nach Hardware; immer 4:2:0, ohne B-Frames und mit kurzem GOP für geringe Verzögerung."""
    if ENCODER == "vaapi":
        return f"vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vah264enc bitrate={BITRATE} key-int-max={GOP} b-frames=0 target-usage=6 ! {H264_CAPS}"
    if ENCODER == "nvenc":
        return f"video/x-raw,format=NV12 ! nvh264enc bitrate={BITRATE} gop-size={GOP} bframes=0 zerolatency=true rc-mode=cbr ! {H264_CAPS}"
    return f"video/x-raw,format=I420 ! x264enc bitrate={BITRATE} key-int-max={GOP} bframes=0 tune=zerolatency speed-preset=veryfast ! {H264_CAPS}"


def pipeline(ndi_name: str, path: str) -> list[str]:
    video = (
        f"d.video ! queue max-size-buffers=3 leaky=downstream ! videoconvert ! videoscale add-borders=true ! videorate drop-only=true ! "
        f"video/x-raw,width={WIDTH},height={HEIGHT},pixel-aspect-ratio=1/1,framerate={FPS}/1 ! videoconvert ! {encoder_chain()} ! "
        f"h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream ! s."
    )
    # Browser spielen per WebRTC nur Stereo-Opus zuverlässig ab – mehrkanaliges NDI-Audio (z. B. 8 Kanäle) auf Stereo mischen
    audio = (
        "d.audio ! queue max-size-time=500000000 leaky=downstream ! audioconvert ! audioresample ! "
        "audio/x-raw,channels=2,rate=48000 ! opusenc bitrate=128000 ! s."
        if AUDIO
        else ""
    )
    desc = (
        f'ndisrc ndi-name="{ndi_name}" timeout=10000 ! ndisrcdemux name=d '
        f"rtspclientsink name=s location={RTSP}/{path} protocols=tcp latency=0 "
        f"{video} {audio}"
    )
    return ["gst-launch-1.0", "-e", *split_args(desc)]


def split_args(desc: str) -> list[str]:
    # gst-launch nimmt die Beschreibung als Argumente; Anführungszeichen um den NDI-Namen erhalten
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


def explain(line: str) -> str:
    """GStreamer-Fehler in verständliche Hinweise übersetzen."""
    if "Could not demultiplex stream" in line or "EOS without available srcpad" in line:
        hint = "Firewall/Netz prüfen" if TRANSPORT == "tcp" else "in den Addon-Einstellungen Übertragung „TCP“ wählen bzw. eingehendes UDP erlauben"
        return f"Keine Bilddaten von der Quelle (Zeitüberschreitung) – Quelle gefunden, aber keine Verbindung: {hint}"
    if "not-negotiated" in line or "not negotiated" in line:
        return f"Format der Quelle nicht verarbeitbar ({line})"
    return line


class Stream:
    def __init__(self, name: str, path: str):
        self.name = name
        self.path = path
        self.proc: subprocess.Popen | None = None
        self.state = "starting"
        self.error = ""
        self.since = time.time()
        self.restarts = 0
        self.next_start = 0.0
        self.tail: list[str] = []

    def start(self) -> None:
        self.state = "starting"
        self.proc = subprocess.Popen(pipeline(self.name, self.path), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        threading.Thread(target=self._read, daemon=True).start()
        log(f"Starte {self.name} → /{self.path} ({ENCODER}, {HEIGHT}p, {BITRATE} kbit/s)")

    def _read(self) -> None:
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            self.tail = (self.tail + [line])[-20:]
            if "PLAYING" in line:
                self.state, self.error, self.since = "running", "", time.time()
            if line.startswith("ERROR") or "erroneous pipeline" in line or "error" in line.lower() and "from element" in line.lower():
                self.error = explain(line)[:300]

    def check(self) -> None:
        if self.proc and self.proc.poll() is not None:
            code = self.proc.returncode
            self.proc = None
            self.state = "error"
            self.error = self.error or f"Pipeline beendet (Code {code})"
            self.restarts += 1
            # Neustart mit Wartezeit (5 s, 10 s … höchstens 60 s)
            self.next_start = time.time() + min(60, 5 * self.restarts)
            log(f"{self.name}: {self.error}")
        if not self.proc and time.time() >= self.next_start:
            self.start()

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None


def start_mdns() -> None:
    """NDI sucht Quellen per mDNS über Avahi (D-Bus) – beides im Container starten."""
    os.makedirs("/run/dbus", exist_ok=True)
    if not os.path.exists("/run/dbus/system_bus_socket"):
        subprocess.Popen(["dbus-daemon", "--system", "--nofork", "--nopidfile"])
        for _ in range(50):
            if os.path.exists("/run/dbus/system_bus_socket"):
                break
            time.sleep(0.1)
    subprocess.Popen(["avahi-daemon", "--no-drop-root", "--no-chroot", "--no-rlimits"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)


def write_ndi_config() -> None:
    """
    NDI-Konfiguration (~/.ndi/ndi-config.v1.json):
    - Übertragung: Standard ist Reliable UDP – dabei schickt die Quelle UDP-Pakete zurück an den Empfänger, die hinter
      NAT, Firewalls oder in Docker Desktop verloren gehen („Could not demultiplex stream“). Mit TCP laufen die Daten
      über die Verbindung, die das Gateway selbst aufbaut.
    - optional NDI Discovery Server statt mDNS (z. B. in großen oder gerouteten Netzen).
    """
    ndi: dict = {}
    if TRANSPORT == "tcp":
        ndi.update({"rudp": {"recv": {"enable": False}}, "unicast": {"recv": {"enable": False}}, "multicast": {"recv": {"enable": False}}, "tcp": {"recv": {"enable": True}}})
    if DISCOVERY:
        ndi["networks"] = {"discovery": DISCOVERY}
    os.makedirs(os.path.expanduser("~/.ndi"), exist_ok=True)
    with open(os.path.expanduser("~/.ndi/ndi-config.v1.json"), "w") as f:
        json.dump({"ndi": ndi}, f)
    log(f"NDI-Empfang über {'TCP' if TRANSPORT == 'tcp' else 'Reliable UDP'}" + (f", Discovery Server {DISCOVERY}" if DISCOVERY else ""))


def check_encoder() -> str:
    element = {"cpu": "x264enc", "vaapi": "vah264enc", "nvenc": "nvh264enc"}.get(ENCODER, "x264enc")
    if Gst.ElementFactory.find(element):
        return ""
    hint = {
        "vaapi": "kein VA-API-Encoder gefunden – ist /dev/dri vorhanden und der Treiber passend (Intel/AMD)?",
        "nvenc": "kein NVENC gefunden – NVIDIA-Treiber und NVIDIA Container Toolkit auf dem Host installiert?",
    }.get(ENCODER, "x264enc fehlt im Image")
    return f"Encoder „{ENCODER}“ nicht verfügbar: {hint}"


def write_status(sources: list[str], streams: dict[str, Stream], problem: str) -> None:
    data = {
        "updatedAt": time.time(),
        "encoder": ENCODER,
        "resolution": f"{WIDTH}x{HEIGHT}",
        "problem": problem,
        "sources": sources,
        "streams": [
            {"name": s.name, "path": s.path, "state": s.state, "error": s.error, "since": s.since, "restarts": s.restarts}
            for s in streams.values()
        ],
    }
    tmp = STATUS_FILE + ".tmp"
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, STATUS_FILE)


class StatusHandler(http.server.BaseHTTPRequestHandler):
    """Liefert nur die Statusdatei aus – keine Steuerung über das Netz."""

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?")[0] not in ("/", "/status.json"):
            self.send_error(404)
            return
        try:
            with open(STATUS_FILE, "rb") as f:
                body = f.read()
        except OSError:
            body = b'{"problem": "Gateway startet"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def serve_status() -> None:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"Status unter :{STATUS_PORT}/status.json")


def wanted(name: str) -> bool:
    return not FILTERS or any(f in name.lower() for f in FILTERS)


def main() -> None:
    serve_status()
    if not os.path.exists(os.path.join(NDI_DIR, "libndi.so.6")):
        log(f"NDI-Bibliothek fehlt in {NDI_DIR} – den Job „NDI-Laufzeit laden“ ausführen (nach Zustimmung zur NDI-Lizenz).")
        write_status([], {}, "NDI-Laufzeit fehlt – Job „NDI-Laufzeit laden“ ausführen")
        time.sleep(30)
        sys.exit(1)
    write_ndi_config()
    start_mdns()
    Gst.init(None)
    problem = check_encoder()
    if problem:
        log(problem)

    monitor = Gst.DeviceMonitor.new()
    monitor.add_filter("Source/Network", None)
    monitor.start()
    log(f"Suche NDI-Quellen … (Filter: {', '.join(FILTERS) or 'alle'}, höchstens {MAX_STREAMS})")

    streams: dict[str, Stream] = {}
    missing_since: dict[str, float] = {}
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    while not stop.is_set():
        names = sorted({d.get_properties().get_string("ndi-name") or d.get_display_name() for d in monitor.get_devices()})
        now = time.time()
        if not problem:
            for name in names:
                if wanted(name) and name not in streams and len(streams) < MAX_STREAMS:
                    path = slug(name)
                    while any(s.path == path for s in streams.values()):
                        path += "-2"
                    streams[name] = Stream(name, path)
            for name, s in list(streams.items()):
                if name in names:
                    missing_since.pop(name, None)
                    s.check()
                elif now - missing_since.setdefault(name, now) > 60:
                    # Quelle seit einer Minute verschwunden → Strom beenden
                    log(f"{name}: nicht mehr im Netz, Strom beendet")
                    s.stop()
                    del streams[name]
                    missing_since.pop(name, None)
                else:
                    s.check()
        write_status(names, streams, problem)
        stop.wait(3)

    for s in streams.values():
        s.stop()
    monitor.stop()


if __name__ == "__main__":
    main()
