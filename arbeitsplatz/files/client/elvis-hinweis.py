#!/usr/bin/python3
"""Hinweis beim Start der Sitzung: Anpassungen gelten nur für das Profil dieses Einsatzes."""
import json
import os
import pwd
import subprocess

name = pwd.getpwuid(os.getuid()).pw_name
try:
    with open(f"/run/elvis-client/session/{name}.json") as f:
        s = json.load(f)
except (OSError, ValueError):
    raise SystemExit(0)

inc = s.get("incident")
if inc:
    label = " ".join(p for p in (inc.get("keyword"), inc.get("title")) if p)
    text = (
        f"<p>Willkommen, {s['user']}.</p>"
        f"<p>Ihre Anpassungen am Desktop gelten nur für den aktuellen Einsatz<br><b>„{label}“ (ID {inc['id']})</b>.</p>"
        "<p>In einem neuen Einsatz erhalten Sie ein neues, leeres Profil. Dateien, die Sie behalten möchten, bitte in ELVIS ablegen.</p>"
    )
else:
    text = (
        f"<p>Willkommen, {s['user']}.</p>"
        "<p>Zurzeit ist <b>kein Einsatz</b> aufgelegt. Ihre Anpassungen am Desktop gelten nur, bis ein Einsatz beginnt – "
        "dann erhalten Sie ein neues, leeres Profil.</p>"
    )
if s.get("offline"):
    text += "<p><i>ELVIS war bei der Anmeldung nicht erreichbar (Offline-Anmeldung).</i></p>"
subprocess.run(["kdialog", "--title", "ELVIS Arbeitsplatz", "--msgbox", text])
