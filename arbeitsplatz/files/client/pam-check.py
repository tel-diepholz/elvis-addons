#!/usr/bin/python3
"""PAM (pam_exec expose_authtok): prüft das Einmalpasswort, das elvis-clientd nach der PIN-Prüfung ausgestellt hat.

Nur ELVIS-Profilkonten (eXuY); jedes Einmalpasswort gilt einmal und 30 Sekunden.
"""
import hashlib
import hmac
import json
import os
import re
import sys
import time

user = os.environ.get("PAM_USER", "")
if os.environ.get("PAM_TYPE") != "auth" or not re.fullmatch(r"e\d+u\d+", user):
    sys.exit(1)
token = sys.stdin.read(256).split("\0")[0].strip()
path = f"/run/elvis-client/otp/{user}"
try:
    with open(path) as f:
        entry = json.load(f)
    os.unlink(path)
except (OSError, ValueError):
    sys.exit(1)
ok = entry.get("expires", 0) > time.time() and hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), entry.get("hash", ""))
sys.exit(0 if ok else 1)
