#!/bin/sh
# Startet ProxyDHCP/TFTP und HTTP auf der Schnittstelle ins Netz der Notebooks.
# DHCP-Adressen vergibt weiter der Router; dnsmasq ergänzt nur die Angaben für den Netzwerkstart.
set -eu

IFACE="${INTERFACE:-}"
[ -n "$IFACE" ] || IFACE=$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$IFACE" ] || { echo "Keine Schnittstelle gefunden (Option „Netzwerkschnittstelle“ setzen)" >&2; exit 1; }
CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
[ -n "$CIDR" ] || { echo "Schnittstelle $IFACE hat keine IPv4-Adresse" >&2; exit 1; }
ADDR=${CIDR%/*}
NET=$(ipcalc -n "$CIDR" | cut -d= -f2)
PORT="${HTTP_PORT:-8089}"
BASE="http://$ADDR:$PORT"
echo "Netzwerkstart auf $IFACE ($CIDR), Netz $NET, HTTP $BASE"

[ -f /data/images/rootfs.tar.zst ] || echo "WARNUNG: Abbild fehlt – Job „Abbild bauen“ ausführen" >&2

# TFTP-Verzeichnis: Startdateien aus dem Volume, Menüs mit der eigenen Adresse
rm -rf /srv/tftp && mkdir -p /srv/tftp/grub /srv/tftp/pxelinux.cfg
cp -a /data/tftp/. /srv/tftp/
render() { sed -e "s|@BASE@|$BASE|g" -e "s|@VERSION@|$(cat /data/images/VERSION 2>/dev/null || echo unbekannt)|g" "$1"; }
render /usr/share/elvis/grub.cfg.in > /srv/tftp/grub/grub.cfg
render /usr/share/elvis/pxelinux.cfg.in > /srv/tftp/pxelinux.cfg/default

# Konfiguration für den Installer (Werte base64, damit Sonderzeichen im Passwort nichts kaputt machen)
mkdir -p /srv/config
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
{
  echo "ELVIS_URL=$(b64 "$ELVIS_URL")"
  echo "ENROLL_TOKEN=$(b64 "$ENROLL_TOKEN")"
  echo "HOSTNAME_PREFIX=$(b64 "${HOSTNAME_PREFIX:-elvis-ap}")"
  echo "ADMIN_HASH=$(b64 "$(printf '%s' "$ADMIN_PASSWORD" | openssl passwd -6 -stdin)")"
  echo "IMAGE_URL=$(b64 "$BASE/images/rootfs.tar.zst")"
  echo "IMAGE_SIZE=$(b64 "$(cat /data/images/rootfs.size 2>/dev/null || echo 0)")"
  echo "IMAGE_VERSION=$(b64 "$(cat /data/images/VERSION 2>/dev/null || echo unbekannt)")"
} > /srv/config/installer.env
chmod 0644 /srv/config/installer.env

sed -i "s|@PORT@|$PORT|" /etc/nginx/nginx.conf
nginx

cat > /etc/dnsmasq.conf <<CONF
port=0
interface=$IFACE
bind-interfaces
dhcp-range=$NET,proxy
log-dhcp
enable-tftp
tftp-root=/srv/tftp
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
pxe-service=tag:!efi64,x86PC,"ELVIS Arbeitsplatz (BIOS)",lpxelinux
pxe-service=tag:efi64,X86-64_EFI,"ELVIS Arbeitsplatz (UEFI)",bootx64.efi
pxe-service=tag:efi64,BC_EFI,"ELVIS Arbeitsplatz (UEFI)",bootx64.efi
CONF
exec dnsmasq --keep-in-foreground --log-facility=- --conf-file=/etc/dnsmasq.conf
