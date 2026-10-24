#!/usr/bin/python3
"""ELVIS-Arbeitsplatz-Dienst.

Hält Benutzer und laufenden Einsatz aus ELVIS vor (auch für den Offline-Betrieb), prüft PINs für die Anmeldemaske
und legt je Benutzer und Einsatz ein lokales Profilkonto an (eXuY, UID 50000–59999). Die Anmeldemaske (SDDM-Theme)
spricht ihn über http://127.0.0.1:7171 an; SDDM meldet danach das Konto mit einem Einmalpasswort an, das pam-check prüft.
"""
import hashlib
import hmac
import json
import os
import pwd
import re
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.2.0"
CONFIG = "/etc/elvis/client.json"
STATE_DIR = "/var/lib/elvis-client"
RUN_DIR = "/run/elvis-client"
CACHE = f"{STATE_DIR}/cache.json"
VERIFIERS = f"{STATE_DIR}/verifiers.json"
UPDATE_FILE = f"{STATE_DIR}/update.json"  # zuletzt bearbeiteter Update-Auftrag
WIFI_FILE = f"{STATE_DIR}/wifi.json"  # Stand der hinterlegten Betriebs-WLAN-Verbindung
WIFI_CONNECTION = "ELVIS Betrieb"
LISTEN = ("127.0.0.1", 7171)
SYNC_S = 30
HEARTBEAT_S = 60
OTP_S = 30
UID_MIN, UID_MAX = 50000, 59999
ACCOUNT = re.compile(r"^e(\d+)u(\d+)$")
GROUPS = ["audio", "video", "plugdev", "lpadmin", "netdev"]

lock = threading.RLock()


def log(*args):
    print(*args, flush=True)


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(path, data, mode=0o600):
    tmp = f"{path}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


config = load(CONFIG, {})
ELVIS = config.get("elvisUrl", "").rstrip("/")
TOKEN = config.get("token", "")


class Offline(Exception):
    """ELVIS nicht erreichbar (Netz, Zeitüberschreitung, Serverfehler)"""


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{ELVIS}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=6) as res:
            raw = res.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code >= 500:
            raise Offline(f"HTTP {e.code}")
        try:
            msg = json.loads(e.read()).get("error", f"HTTP {e.code}")
        except ValueError:
            msg = f"HTTP {e.code}"
        raise ApiError(e.code, msg)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Offline(str(e))


# --- Zustand: Cache aus ELVIS, Offline-Verifier, Sperren ---

cache = load(CACHE, {"users": [], "incident": None, "workstation": None, "lastSync": None, "revoked": False})
verifiers = load(VERIFIERS, {})  # userId (str) → {salt, hash, stamp}
online = False
last_error = None  # letzter Verbindungsfehler für die Anmeldemaske


def is_revoked_error(e):
    return e.status == 401 and "nicht registriert" in e.message


def revoke():
    """In ELVIS entfernt: keine Anmeldung mehr, auch nicht offline"""
    global verifiers
    with lock:
        if cache.get("revoked") and not cache["users"] and not verifiers:
            return
        cache.update(users=[], incident=None, revoked=True)
        verifiers = {}
        save(CACHE, cache)
        save(VERIFIERS, verifiers)
    log("Arbeitsplatz in ELVIS gesperrt – Anmeldedaten verworfen")


def sync():
    global online, verifiers, last_error
    try:
        state = api("GET", "/api/clients/state")
    except Offline as e:
        if online or last_error is None:
            log("ELVIS nicht erreichbar:", e)
        online = False
        last_error = describe(e)
        return
    except ApiError as e:
        online = True
        last_error = None if is_revoked_error(e) else e.message
        if is_revoked_error(e):
            revoke()
        return
    with lock:
        online = True
        last_error = None
        stamps = {str(u["id"]): u["pinStamp"] for u in state["users"]}
        # PIN geändert oder Benutzer gelöscht → Offline-Verifier verwerfen
        verifiers = {k: v for k, v in verifiers.items() if stamps.get(k) == v.get("stamp")}
        cache.update(users=state["users"], incident=state["incident"], workstation=state["workstation"], lastSync=state["serverTime"], revoked=False)
        save(CACHE, cache)
        save(VERIFIERS, verifiers)
    if "wifi" in state:  # ältere ELVIS-Versionen liefern kein WLAN – dann nichts anfassen
        apply_wifi(state["wifi"])
    check_update(state.get("update"))


# --- Betriebs-WLAN aus ELVIS als systemweite Verbindung (NetworkManager) ---


def apply_wifi(wifi):
    """Verbindung „ELVIS Betrieb“ anlegen, ändern oder entfernen – nur wenn sich etwas geändert hat"""
    want = {"ssid": wifi["ssid"], "psk": hashlib.sha256(wifi["psk"].encode()).hexdigest()} if wifi else None
    if load(WIFI_FILE, {}).get("applied") == want:
        return
    nm = ["nmcli", "--wait", "10"]
    try:
        names = subprocess.run(nm + ["-t", "-f", "NAME", "connection", "show"], capture_output=True, text=True, timeout=15).stdout.splitlines()
        exists = WIFI_CONNECTION in names
        if wifi:
            settings = [
                "802-11-wireless.ssid", wifi["ssid"],
                "802-11-wireless.mode", "infrastructure",
                "wifi-sec.key-mgmt", "wpa-psk",
                "wifi-sec.psk", wifi["psk"],
                "connection.autoconnect", "yes",
                "connection.autoconnect-priority", "10",
                "connection.permissions", "",
                "ipv4.method", "auto",
                "ipv6.method", "auto",
            ]  # fmt: skip
            cmd = nm + (["connection", "modify", WIFI_CONNECTION] if exists else ["connection", "add", "type", "wifi", "con-name", WIFI_CONNECTION, "ifname", "*"]) + settings
        elif exists:
            cmd = nm + ["connection", "delete", WIFI_CONNECTION]
        else:
            cmd = None
        if cmd:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                log("Betriebs-WLAN: nmcli fehlgeschlagen:", (r.stderr or r.stdout).strip())
                return
        save(WIFI_FILE, {"applied": want})
        log(f"Betriebs-WLAN: {'„' + wifi['ssid'] + '“ hinterlegt' if wifi else 'Verbindung entfernt'}")
    except (OSError, subprocess.SubprocessError) as e:
        log("Betriebs-WLAN: NetworkManager nicht erreichbar:", e)


# --- Updates (von ELVIS angestoßen; nur wenn niemand angemeldet ist) ---

updating = None  # laufendes Update: {"id", "message"} – sperrt die Anmeldung
UPDATE_LOG_MAX = 20_000
APT_SOURCES = "/etc/apt/sources.disabled"  # Paketquellen, die nur während eines Updates gelten


def report_update(order_id, state, message, log_text=""):
    try:
        api("POST", "/api/clients/update", {"id": order_id, "state": state, "message": message[:300], "log": log_text[-UPDATE_LOG_MAX:]})
        return True
    except (Offline, ApiError) as e:
        log("Update-Rückmeldung fehlgeschlagen:", e)
        return False


def check_update(order):
    """Auftrag aus dem Abgleich: abgeschlossene erneut melden, neue starten, sobald niemand angemeldet ist"""
    global updating
    if not order:
        return
    with lock:
        if updating:
            return
        last = load(UPDATE_FILE, {})
        if last.get("id") == order["id"]:
            if last.get("state") == "running":
                # Dienst oder Gerät während des Updates neu gestartet
                last.update(state="failed", message="Unterbrochen (Neustart während des Updates)")
                save(UPDATE_FILE, last)
            report_update(last["id"], last["state"], last.get("message", ""), last.get("log", ""))
            return
        # vor der Prüfung sperren, damit sich niemand dazwischen anmeldet
        updating = {"id": order["id"], "message": "Update wird vorbereitet …"}
    if active_user():
        with lock:
            updating = None
        return
    threading.Thread(target=run_update, args=(order,), daemon=True).start()


class UpdateRun:
    """Befehle ausführen, Ausgabe sammeln und den Stand regelmäßig an ELVIS melden"""

    def __init__(self, order):
        self.order = order
        self.out = ""
        self.last_report = 0.0

    def status(self, message):
        global updating
        with lock:
            updating = {"id": self.order["id"], "message": message}
        self.out += f"\n== {message}\n"
        self.flush(force=True)

    def flush(self, force=False):
        if force or time.time() - self.last_report > 15:
            self.last_report = time.time()
            report_update(self.order["id"], "running", updating["message"] if updating else "", self.out)

    def run(self, cmd, env=None, ok=(0,)):
        self.out += "$ " + " ".join(cmd) + "\n"
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env={**os.environ, **(env or {})})
        for line in p.stdout:
            self.out = (self.out + line)[-UPDATE_LOG_MAX:]
            self.flush()
        code = p.wait()
        if code not in ok:
            raise RuntimeError(f"{cmd[0]} {cmd[1] if len(cmd) > 1 else ''} beendet mit Code {code}")
        return code


def run_update(order):
    global updating
    proxy = order["aptProxy"]
    run = UpdateRun(order)
    save(UPDATE_FILE, {"id": order["id"], "state": "running"})
    summary = []
    reboot = False
    try:
        if order.get("apt") or (order.get("firmware") and not os.path.exists("/usr/bin/fwupdmgr")):
            apt = [
                "apt-get", "-q",
                "-o", f"Acquire::http::Proxy={proxy}", "-o", f"Acquire::https::Proxy={proxy}",
                "-o", "Dir::Etc::SourceList=/dev/null", "-o", f"Dir::Etc::SourceParts={APT_SOURCES}",
                "-o", "APT::Install-Recommends=false",
                "-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold",
            ]  # fmt: skip
            env = {"DEBIAN_FRONTEND": "noninteractive"}
            run.status("Paketlisten laden")
            run.run(apt + ["update"], env)
            if order.get("apt"):
                run.status("Pakete aktualisieren")
                before = len(run.out)
                run.run(apt + ["-y", "dist-upgrade"], env)
                m = re.search(r"(\d+) (?:upgraded|aktualisiert)", run.out[before:])
                summary.append(f"{m.group(1) if m else '?'} Pakete aktualisiert")
                run.run(apt + ["-y", "autoremove", "--purge"], env)
            if order.get("firmware") and not os.path.exists("/usr/bin/fwupdmgr"):
                run.status("fwupd installieren")
                run.run(apt + ["-y", "install", "fwupd"], env)
            run.run(["apt-get", "clean"])
            # Paketlisten wieder verwerfen: ohne Auftrag sucht das System weiterhin nichts
            subprocess.run(["sh", "-c", "rm -rf /var/lib/apt/lists/*"])
            reboot = os.path.exists("/run/reboot-required")
        if order.get("firmware"):
            env = {"http_proxy": proxy, "https_proxy": proxy, "HTTP_PROXY": proxy, "HTTPS_PROXY": proxy}
            run.status("Firmware-Liste laden (LVFS)")
            run.run(["fwupdmgr", "refresh", "--force", "-y"], env, ok=(0, 2))
            run.status("Firmware aktualisieren")
            # 2 = nichts zu tun
            code = run.run(["fwupdmgr", "update", "-y", "--no-reboot-check"], env, ok=(0, 2))
            summary.append("Firmware aktualisiert" if code == 0 else "Firmware aktuell")
            reboot = reboot or code == 0
        message = ", ".join(summary) + (" – Neustart" if reboot else "")
        state = "done"
    except Exception as e:  # noqa: BLE001 – jeder Fehler beendet das Update mit Meldung
        message = str(e)[:300]
        state = "failed"
        reboot = False
    log(f"Update {order['id']}: {state} – {message}")
    save(UPDATE_FILE, {"id": order["id"], "state": state, "message": message, "log": run.out[-UPDATE_LOG_MAX:]})
    report_update(order["id"], state, message, run.out)
    with lock:
        updating = None if not reboot else {"id": order["id"], "message": "Neustart …"}
    if reboot:
        subprocess.run(["systemctl", "reboot"])


def describe(e):
    """Verbindungsfehler verständlich für die Anmeldemaske"""
    text = str(e)
    if "Network is unreachable" in text or "No route to host" in text:
        return "Kein Netzwerk – Kabel oder WLAN prüfen"
    if "Connection refused" in text:
        return f"{ELVIS} lehnt die Verbindung ab"
    if "timed out" in text:
        return f"{ELVIS} antwortet nicht"
    if "Name or service not known" in text or "Temporary failure in name resolution" in text:
        return "Adresse von ELVIS unbekannt (DNS)"
    return text[:120]


def scrypt(pin, salt):
    return hashlib.scrypt(pin.encode(), salt=bytes.fromhex(salt), n=2**15, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32).hex()


class Limiter:
    """Wie in ELVIS: je Benutzer wachsende Sperre nach 3 Fehlversuchen, je Gerät 10 Fehlversuche in 10 min"""

    def __init__(self):
        self.users = {}
        self.device = []
        self.device_locked = 0.0

    def check(self, uid):
        now = time.time()
        if self.device_locked > now:
            raise ApiError(429, f"Zu viele Fehlversuche an diesem Gerät – erneut möglich in {wait(self.device_locked - now)}")
        u = self.users.get(uid)
        if u and u["locked"] > now:
            raise ApiError(429, f"Zu viele falsche PINs für diesen Benutzer – erneut möglich in {wait(u['locked'] - now)}")

    def failure(self, uid):
        now = time.time()
        u = self.users.setdefault(uid, {"failures": 0, "locked": 0.0})
        u["failures"] += 1
        if u["failures"] >= 3:
            u["locked"] = now + min(900, 30 * 2 ** (u["failures"] - 3))
        self.device = [t for t in self.device if now - t < 600] + [now]
        if len(self.device) >= 10:
            self.device_locked = now + 600
        return max(0, 3 - u["failures"])

    def success(self, uid):
        self.users.pop(uid, None)


def wait(s):
    return f"{int(s // 60) + 1} min" if s >= 60 else f"{int(s) + 1} s"


limiter = Limiter()


# --- Profilkonten ---


def account_name(incident, user_id):
    return f"e{incident['id'] if incident else 0}u{user_id}"


def ensure_account(name, user, incident):
    try:
        pwd.getpwnam(name)
        return
    except KeyError:
        pass
    where = f"Einsatz {incident['id']}" if incident else "ohne Einsatz"
    gecos = f"{user['firstName']} {user['lastName']} ({where})".replace(":", " ").replace(",", " ")
    groups = [g for g in GROUPS if subprocess.run(["getent", "group", g], capture_output=True).returncode == 0]
    subprocess.run(
        ["useradd", "-m", "-s", "/bin/bash", "-c", gecos, "-K", f"UID_MIN={UID_MIN}", "-K", f"UID_MAX={UID_MAX}", "-G", ",".join(groups), "-p", "!", name],
        check=True,
        capture_output=True,
    )
    log(f"Profil {name} angelegt ({gecos})")


def issue_otp(name, user, incident, offline):
    os.makedirs(f"{RUN_DIR}/otp", mode=0o700, exist_ok=True)
    os.makedirs(f"{RUN_DIR}/session", mode=0o755, exist_ok=True)
    otp = secrets.token_urlsafe(24)
    save(f"{RUN_DIR}/otp/{name}", {"hash": hashlib.sha256(otp.encode()).hexdigest(), "expires": time.time() + OTP_S})
    # Für den Hinweis beim Start der Sitzung (lesbar für den Benutzer)
    save(f"{RUN_DIR}/session/{name}.json", {"user": f"{user['firstName']} {user['lastName']}", "incident": incident, "offline": offline}, mode=0o644)
    return otp


def verify_pin(user_id, pin, purpose="login"):
    """PIN prüfen: online über ELVIS (merkt sich den Offline-Verifier), sonst gegen den Verifier.
    Liefert (Benutzer, Einsatz, offline)."""
    with lock:
        user = next((u for u in cache["users"] if u["id"] == user_id), None)
        if cache.get("revoked"):
            raise ApiError(403, "Dieser Arbeitsplatz ist in ELVIS gesperrt – bitte neu installieren")
    if not user:
        raise ApiError(404, "Benutzer unbekannt")
    if not re.fullmatch(r"\d{4}", pin or ""):
        raise ApiError(400, "Die PIN hat 4 Ziffern")
    limiter.check(user_id)

    offline = False
    try:
        result = api("POST", "/api/clients/login", {"userId": user_id, "pin": pin, "purpose": purpose})
        incident = result["incident"]
        salt = secrets.token_hex(16)
        with lock:
            verifiers[str(user_id)] = {"salt": salt, "hash": scrypt(pin, salt), "stamp": result["user"]["pinStamp"]}
            cache["incident"] = incident
            save(VERIFIERS, verifiers)
            save(CACHE, cache)
        limiter.success(user_id)
    except ApiError as e:
        if is_revoked_error(e):
            revoke()
            raise ApiError(403, "Dieser Arbeitsplatz ist in ELVIS gesperrt – bitte neu installieren")
        if e.status == 401:
            limiter.failure(user_id)
        raise
    except Offline:
        offline = True
        with lock:
            v = verifiers.get(str(user_id))
            incident = cache.get("incident")
        if not v or v.get("stamp") != user.get("pinStamp"):
            raise ApiError(503, "ELVIS ist nicht erreichbar – offline können sich nur Benutzer anmelden, die sich an diesem Gerät schon einmal angemeldet haben")
        if not hmac.compare_digest(scrypt(pin, v["salt"]), v["hash"]):
            left = limiter.failure(user_id)
            raise ApiError(401, f"PIN falsch – noch {left} Versuch{'e' if left != 1 else ''}" if left else "PIN falsch – Anmeldung vorübergehend gesperrt")
        limiter.success(user_id)
    return user, incident, offline


def login(user_id, pin):
    with lock:
        if updating:
            raise ApiError(503, "Update läuft – Anmeldung danach wieder möglich")
    user, incident, offline = verify_pin(user_id, pin)
    name = account_name(incident, user_id)
    ensure_account(name, user, incident)
    otp = issue_otp(name, user, incident, offline)
    log(f"Anmeldung {user['firstName']} {user['lastName']} als {name}{' (offline)' if offline else ''}")
    return {"account": name, "otp": otp, "incident": incident, "offline": offline}


def unlock(account, pin):
    """Bildschirmsperre der laufenden Sitzung aufheben: PIN des ELVIS-Benutzers, dem das Profilkonto gehört"""
    m = ACCOUNT.match(account or "")
    if not m:
        raise ApiError(400, "Kein ELVIS-Profilkonto")
    user, _, offline = verify_pin(int(m.group(2)), pin, purpose="unlock")
    log(f"Entsperrt: {user['firstName']} {user['lastName']} ({account}){' offline' if offline else ''}")
    return {"ok": True}


def public_state():
    with lock:
        return {
            "online": online,
            "revoked": bool(cache.get("revoked")),
            "updating": updating,
            "configured": bool(ELVIS and TOKEN),
            "error": None if online else (last_error if ELVIS and TOKEN else f"{CONFIG} fehlt – Arbeitsplatz neu installieren"),
            "lastSync": cache.get("lastSync"),
            "workstation": cache.get("workstation"),
            "incident": cache.get("incident"),
            "users": [
                {"id": u["id"], "firstName": u["firstName"], "lastName": u["lastName"], "offlineReady": verifiers.get(str(u["id"]), {}).get("stamp") == u["pinStamp"]}
                for u in cache["users"]
            ],
        }


# --- Lebenszeichen und Hintergrundarbeit ---


def active_user():
    """Name des angemeldeten ELVIS-Benutzers (grafische Sitzung), sonst None"""
    try:
        out = subprocess.run(["loginctl", "list-sessions", "--no-legend"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        parts = line.split()
        name = next((p for p in parts if ACCOUNT.match(p)), None)
        if name:
            try:
                return pwd.getpwnam(name).pw_gecos.split(" (")[0] or name
            except KeyError:
                return name
    return None


def background():
    last_beat = 0.0
    while True:
        if ELVIS and TOKEN:
            sync()
            if online and not cache.get("revoked") and time.time() - last_beat >= HEARTBEAT_S:
                try:
                    api("POST", "/api/clients/heartbeat", {"version": VERSION, "user": active_user()})
                    last_beat = time.time()
                except (Offline, ApiError):
                    pass
        time.sleep(SYNC_S if online else 10)


def write_browser_defaults():
    """Startseite ELVIS, keine Update-Prüfung im Browser"""
    if not ELVIS:
        return
    with open("/etc/elvis/url", "w") as f:
        f.write(ELVIS + "\n")
    os.chmod("/etc/elvis/url", 0o644)
    os.chmod("/etc/elvis", 0o755)
    policies = {
        "policies": {
            "Homepage": {"URL": ELVIS, "StartPage": "homepage", "Locked": False},
            "DisableAppUpdate": True,
            "DisableTelemetry": True,
            "DisableFirefoxStudies": True,
            "DontCheckDefaultBrowser": True,
            "OverrideFirstRunPage": "",
            "OverridePostUpdatePage": "",
            "NoDefaultBookmarks": True,
            "ManagedBookmarks": [{"toplevel_name": "ELVIS"}, {"name": "ELVIS", "url": ELVIS}],
            "DisplayBookmarksToolbar": "always",
        }
    }
    os.makedirs("/etc/firefox/policies", exist_ok=True)
    save("/etc/firefox/policies/policies.json", policies, mode=0o644)


class Handler(BaseHTTPRequestHandler):
    server_version = "elvis-clientd"

    def send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/state":
            return self.send(200, public_state())
        self.send(404, {"error": "Nicht gefunden"})

    def do_POST(self):
        if self.path not in ("/login", "/unlock"):
            return self.send(404, {"error": "Nicht gefunden"})
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 4096)
            body = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/unlock":
                return self.send(200, unlock(str(body.get("account", "")), str(body.get("pin", ""))))
            self.send(200, login(int(body.get("userId", 0)), str(body.get("pin", ""))))
        except ApiError as e:
            self.send(e.status, {"error": e.message})
        except (ValueError, TypeError):
            self.send(400, {"error": "Ungültige Anfrage"})
        except subprocess.CalledProcessError as e:
            log("Profil anlegen fehlgeschlagen:", e.stderr)
            self.send(500, {"error": "Profil konnte nicht angelegt werden"})

    def log_message(self, fmt, *args):
        pass


def main():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    os.makedirs(RUN_DIR, mode=0o755, exist_ok=True)
    if not (ELVIS and TOKEN):
        log(f"{CONFIG} fehlt oder ist unvollständig – Anmeldung nicht möglich")
    write_browser_defaults()
    threading.Thread(target=background, daemon=True).start()
    log(f"elvis-clientd {VERSION} für {ELVIS or '?'} auf {LISTEN[0]}:{LISTEN[1]}")
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()


if __name__ == "__main__":
    main()
