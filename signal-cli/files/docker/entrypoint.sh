#!/bin/sh
# signal-cli nur im Container (127.0.0.1:8081), nginx davor mit Token-Prüfung (Port 8080)
set -eu

if [ -z "${ELVIS_TOKEN:-}" ] || [ "${#ELVIS_TOKEN}" -lt 16 ]; then
  echo "ELVIS_TOKEN fehlt oder ist zu kurz" >&2
  exit 1
fi

chown -R signal /var/lib/signal-cli
TEMPLATE=/data/addon/nginx.conf.template
if [ ! -f "$TEMPLATE" ]; then
  echo "$TEMPLATE fehlt – Addon in ELVIS neu installieren bzw. aktualisieren" >&2
  exit 1
fi
envsubst '${ELVIS_TOKEN}' < "$TEMPLATE" > /tmp/nginx.conf

# Mehrere Konten möglich (ohne --account); ELVIS wählt das Konto
su -s /bin/sh signal -c 'exec signal-cli --config /var/lib/signal-cli daemon --http=127.0.0.1:8081 --receive-mode=on-start --send-read-receipts' &
SIGNAL_PID=$!

nginx -c /tmp/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

# Endet einer der beiden, endet der Container (Docker startet ihn neu)
while kill -0 "$SIGNAL_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do sleep 5; done
kill "$SIGNAL_PID" "$NGINX_PID" 2>/dev/null || true
exit 1
