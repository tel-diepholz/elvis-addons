#!/bin/sh
# Gastdrucker: ein eigener CUPS mit genau einer Warteschlange, die jeder im Gastnetz findet (Bonjour/mDNS) und ohne
# App oder Treiber nutzen kann – iOS (AirPrint), Android (Standarddruckdienst), Windows 10/11 (IPP-Klassentreiber).
# CUPS wandelt, was die Geräte schicken (PDF, JPEG, Apple- und PWG-Raster), in PDF; das Backend „elvis“ reicht es an
# ELVIS weiter, das je nach Einstellung sofort druckt oder auf Freigabe wartet.
set -eu

if [ "${GUEST_ENABLED:-false}" != "true" ]; then
  echo "Gastdrucker ist in den Addon-Optionen abgeschaltet."
  trap 'exit 0' TERM INT
  while :; do sleep 3600 & wait $!; done
fi

: "${ELVIS_URL:?Option „Adresse von ELVIS“ fehlt – ohne sie kann der Gastdrucker keine Aufträge weitergeben}"
: "${ELVIS_TOKEN:?ELVIS_TOKEN fehlt}"
PORT=${GUEST_PORT:-8631}
NAME=${GUEST_NAME:-ELVIS Gastdrucker}
IFACE=${GUEST_INTERFACE:-}

# Nur auf der Schnittstelle zum Gastnetz lauschen, wenn angegeben
listen="*:$PORT"
if [ -n "$IFACE" ]; then
  addr=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
  if [ -z "$addr" ]; then
    echo "Schnittstelle $IFACE hat keine IPv4-Adresse – Gastdrucker startet nicht. Neuer Versuch in 30 s." >&2
    sleep 30
    exit 1
  fi
  listen="$addr:$PORT"
fi

# Zugangsdaten für das Backend (CUPS startet Backends ohne die Umgebung des Containers)
umask 077
printf 'ELVIS_URL=%s\nELVIS_TOKEN=%s\nGUEST_PORT=%s\n' "'$ELVIS_URL'" "'$ELVIS_TOKEN'" "$PORT" > /etc/cups/elvis-guest.env
umask 022

# Protokolle ins Container-Log
sed -i '/^\(ErrorLog\|AccessLog\|PageLog\) /d' /etc/cups/cups-files.conf
printf 'ErrorLog stderr\nAccessLog stderr\nPageLog stderr\n' >> /etc/cups/cups-files.conf

cat > /etc/cups/cupsd.conf <<CONF
# Vom Addon bei jedem Start geschrieben: nur drucken, keine Verwaltung, keine Aufträge anderer einsehen
LogLevel warn
MaxLogSize 0
Listen $listen
Listen /run/cups/cups.sock
ServerAlias *
Browsing No
WebInterface No
PreserveJobHistory No
PreserveJobFiles No
MaxJobs 100
MaxJobsPerPrinter 100
# Auftragsgröße wie in ELVIS (50 MB)
LimitRequestBody 52428800

<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  Order deny,allow
  Deny all
  Allow localhost
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Validate-Job Send-Document Get-Printer-Attributes Get-Jobs Get-Job-Attributes Cancel-Job Cancel-My-Jobs Close-Job Identify-Printer CUPS-Get-Default CUPS-Get-Printers>
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
    Deny all
    Allow localhost
  </Limit>
</Policy>
CONF

mkdir -p /run/cups
/usr/sbin/cupsd -f &
cups=$!

for _ in $(seq 1 30); do
  lpstat -r >/dev/null 2>&1 && break
  sleep 1
done

# Warteschlange bei jedem Start neu: PDF-Drucker ohne Treiber, Fehler brechen nur den Auftrag ab
lpadmin -x Gastdrucker 2>/dev/null || true
lpadmin -p Gastdrucker -E -v elvis:/ -P /usr/share/elvis/gastdrucker.ppd -D "$NAME" -L "Gastnetz" \
  -o printer-is-shared=true -o printer-error-policy=abort-job -o job-sheets-default=none,none
cupsenable Gastdrucker
cupsaccept Gastdrucker

uuid=$(ipptool -tv "ipp://localhost:$PORT/printers/Gastdrucker" get-printer-attributes.test 2>/dev/null \
  | sed -n 's/.*printer-uuid (uri) = urn:uuid:\([0-9a-fA-F-]*\).*/\1/p' | head -1)

# Bonjour: AirPrint-Ankündigung mit allen Angaben, die iOS, Android und Windows auswerten
esc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
mkdir -p /etc/avahi/services
rm -f /etc/avahi/services/*.service
cat > /etc/avahi/services/elvis-gastdrucker.service <<SVC
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>$(esc "$NAME")</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <subtype>_print._sub._ipp._tcp</subtype>
    <port>$PORT</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/Gastdrucker</txt-record>
    <txt-record>ty=$(esc "$NAME")</txt-record>
    <txt-record>product=(ELVIS Gastdrucker)</txt-record>
    <txt-record>note=Gastnetz</txt-record>
    <txt-record>kind=document</txt-record>
    <txt-record>pdl=application/pdf,image/urf,image/pwg-raster,image/jpeg</txt-record>
    <txt-record>URF=W8,SRGB24,CP99,RS300,DM1,IS1,V1.4</txt-record>
    <txt-record>Color=T</txt-record>
    <txt-record>Duplex=T</txt-record>
    <txt-record>Copies=T</txt-record>
    <txt-record>Transparent=T</txt-record>
    <txt-record>Binary=T</txt-record>
    <txt-record>PaperMax=legal-A4</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x801046</txt-record>${uuid:+
    <txt-record>UUID=$uuid</txt-record>}
  </service>
</service-group>
SVC

# avahi ohne D-Bus, nur auf der Schnittstelle zum Gastnetz
cat > /etc/avahi/avahi-daemon.conf <<CONF
[server]
use-ipv4=yes
use-ipv6=no
enable-dbus=no
${IFACE:+allow-interfaces=$IFACE}
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no

[reflector]
enable-reflector=no
CONF
mkdir -p /run/avahi-daemon
avahi-daemon --no-chroot --no-drop-root --no-rlimits &
avahi=$!

echo "Gastdrucker „$NAME“ auf $listen${IFACE:+ (mDNS auf $IFACE)}, Aufträge an $ELVIS_URL"

trap 'kill -TERM "$cups" "$avahi" 2>/dev/null; wait; exit 0' TERM INT
# Endet einer der Dienste, startet Docker den Container neu
while kill -0 "$cups" 2>/dev/null && kill -0 "$avahi" 2>/dev/null; do sleep 5 & wait $!; done
echo "CUPS oder avahi beendet – Neustart" >&2
exit 1
