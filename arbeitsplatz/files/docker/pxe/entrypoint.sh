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
# Abbilder älterer Bauläufe: Kernel/initrd waren nur für root lesbar (dnsmasq und nginx laufen ohne root)
chmod -R a+rX /srv/tftp
render() { sed -e "s|@BASE@|$BASE|g" -e "s|@HOSTPORT@|$ADDR:$PORT|g" -e "s|@VERSION@|$(cat /data/images/VERSION 2>/dev/null || echo unbekannt)|g" "$1"; }
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

# Installer-ISO mit dieser Adresse (hybrid: CD oder USB-Stick, BIOS mit isolinux, UEFI mit shim/GRUB von Ubuntu).
# Braucht cd/ aus dem Job („Installer neu bauen“); fehlt etwas, gibt es eben keine ISO.
build_iso() {
  W=/tmp/isoroot S=/usr/share/syslinux
  for f in /srv/tftp/installer/vmlinuz /srv/tftp/installer/initrd.img /srv/tftp/cd/bootx64.efi /srv/tftp/cd/grubx64.efi; do
    [ -f "$f" ] || { echo "Installer-ISO: $f fehlt – Job „Installer neu bauen“ ausführen" >&2; return 1; }
  done
  rm -rf "$W" && mkdir -p "$W/installer" "$W/isolinux" "$W/boot/grub" "$W/EFI/boot" "$W/.disk" /srv/iso
  cp /srv/tftp/installer/vmlinuz /srv/tftp/installer/initrd.img "$W/installer/"
  cp "$S/isolinux.bin" "$S/ldlinux.c32" "$S/menu.c32" "$S/libutil.c32" "$S/libcom32.c32" "$W/isolinux/"
  render /usr/share/elvis/isolinux.cfg.in > "$W/isolinux/isolinux.cfg"
  render /usr/share/elvis/iso-grub.cfg.in > "$W/boot/grub/grub.cfg"
  echo "ELVIS Arbeitsplatz Installer $(cat /data/images/VERSION 2>/dev/null)" > "$W/.disk/info"
  cp /srv/tftp/cd/bootx64.efi /srv/tftp/cd/grubx64.efi "$W/EFI/boot/"
  # EFI-Bootabbild (FAT) mit shim und GRUB für El Torito und die GPT-Partition des USB-Sticks
  dd if=/dev/zero of="$W/boot/efi.img" bs=1M count=8 status=none
  mkfs.vfat -n ELVIS_EFI "$W/boot/efi.img" >/dev/null
  mmd -i "$W/boot/efi.img" ::/EFI ::/EFI/boot
  mcopy -i "$W/boot/efi.img" /srv/tftp/cd/bootx64.efi /srv/tftp/cd/grubx64.efi ::/EFI/boot/
  xorriso -as mkisofs -quiet -r -J -l -V ELVIS_INSTALLER \
    -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
    -isohybrid-mbr "$S/isohdpfx.bin" \
    -eltorito-alt-boot -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat \
    -o /srv/iso/elvis-installer.iso.new "$W" && mv /srv/iso/elvis-installer.iso.new /srv/iso/elvis-installer.iso
  rm -rf "$W"
  echo "Installer-ISO: $BASE/iso/elvis-installer.iso ($(du -h /srv/iso/elvis-installer.iso | cut -f1))"
}
build_iso || true

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
