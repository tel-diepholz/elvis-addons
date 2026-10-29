#!/bin/sh
# Startet CUPS: Konfiguration aus dem Addon, Verwaltungsbenutzer und optional Drucker aus der Option „Drucker“.
set -eu

# Zweiter Container des Addons: Gastdrucker
[ "${1:-}" = "guest" ] && exec sh /usr/local/bin/elvis-cups-guest

# /etc/cups liegt im Volume – beim ersten Start die Vorgaben aus dem Image übernehmen
[ -f /etc/cups/cups-files.conf ] || cp -a /etc/cups.dist/. /etc/cups/
cp /data/addon/cupsd.conf /etc/cups/cupsd.conf
# Protokolle ins Container-Log (Addon-Protokolle in ELVIS)
sed -i '/^\(ErrorLog\|AccessLog\|PageLog\) /d' /etc/cups/cups-files.conf
printf 'ErrorLog stderr\nAccessLog stderr\nPageLog stderr\n' >> /etc/cups/cups-files.conf

# Verwaltungsbenutzer „admin“ (Gruppe lpadmin = @SYSTEM)
id admin >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin -G lpadmin admin
echo "admin:${ADMIN_PASSWORD}" | chpasswd

mkdir -p /run/cups
/usr/sbin/cupsd -f &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null; wait "$pid"; exit 0' TERM INT

for _ in $(seq 1 30); do
  lpstat -r >/dev/null 2>&1 && break
  sleep 1
done

# Drucker „Name=Adresse[;Option=Wert…], …“ einrichten, sofern es sie noch nicht gibt.
# Die Optionen setzt das Addon bei jedem Start als Vorgabe der Warteschlange, auch bei bestehenden Druckern.
echo "${PRINTERS:-}" | tr ',' '\n' | while IFS= read -r entry; do
  entry=$(echo "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$entry" ] || continue
  case "$entry" in *=*) ;; *) echo "Drucker „$entry“: Format Name=Adresse erwartet" >&2; continue ;; esac
  name=$(printf '%s' "${entry%%=*}" | sed 's/[[:space:]]*$//' | tr -c 'A-Za-z0-9_-' '_' | cut -c1-127)
  rest=${entry#*=}
  uri=$(echo "${rest%%;*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$rest" in *\;*) options=${rest#*;} ;; *) options= ;; esac
  if ! lpstat -p "$name" >/dev/null 2>&1; then
    if lpadmin -p "$name" -E -v "$uri" -m everywhere -D "$name"; then
      echo "Drucker $name ($uri) eingerichtet"
    else
      echo "Drucker $name ($uri) konnte nicht eingerichtet werden – eingeschaltet, erreichbar und IPP-Everywhere-fähig? Sonst in der CUPS-Verwaltung mit Treiber anlegen. Neuer Versuch beim nächsten Start." >&2
      continue
    fi
  fi
  echo "$options" | tr ';' '\n' | while IFS= read -r option; do
    option=$(echo "$option" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]*=[[:space:]]*/=/')
    [ -n "$option" ] || continue
    if ! echo "$option" | grep -Eq '^[A-Za-z0-9_-]+=[^[:space:]]+$'; then
      echo "Drucker $name: Option „$option“ ignoriert – Format Option=Wert erwartet" >&2
      continue
    fi
    if lpadmin -p "$name" -o "$option"; then
      echo "Drucker $name: $option gesetzt"
    else
      echo "Drucker $name: Option „$option“ konnte nicht gesetzt werden – Name und Werte zeigt „lpoptions -p $name -l“" >&2
    fi
  done
done

wait "$pid"
