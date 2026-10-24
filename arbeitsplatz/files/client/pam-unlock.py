#!/usr/bin/python3
"""PAM (pam_exec expose_authtok) für die Bildschirmsperre: prüft die PIN des ELVIS-Benutzers, dem das
Profilkonto (eXuY) gehört, über elvis-clientd – online über ELVIS, offline gegen den gemerkten Verifier.
Läuft als der angemeldete Benutzer (kscreenlocker), daher über den lokalen Dienst statt über Dateien."""
import json
import os
import re
import sys
import urllib.error
import urllib.request

user = os.environ.get("PAM_USER", "")
if os.environ.get("PAM_TYPE") != "auth" or not re.fullmatch(r"e\d+u\d+", user):
    sys.exit(1)
pin = sys.stdin.read(64).split("\0")[0].strip()
req = urllib.request.Request(
    "http://127.0.0.1:7171/unlock",
    data=json.dumps({"account": user, "pin": pin}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=15) as res:
        sys.exit(0 if res.status == 200 else 1)
except (urllib.error.URLError, OSError, ValueError):
    sys.exit(1)
