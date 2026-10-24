#!/bin/sh
# Signierte Startdateien für den Netzwerkstart: shim + GRUB (UEFI, auch mit Secure Boot) und lpxelinux (BIOS).
set -eu
TFTP=/data/tftp
WORK=/data/work/netboot
rm -rf "$WORK" && mkdir -p "$WORK/deb" "$TFTP"
cd "$WORK/deb"

echo "ELVIS_PROGRESS 5 Pakete laden"
apt-get update -qq
apt-get download -qq shim-signed grub-efi-amd64-signed pxelinux syslinux-common
for d in *.deb; do dpkg-deb -x "$d" "$WORK/x"; done

echo "ELVIS_PROGRESS 60 Dateien ablegen"
X="$WORK/x"
# shim lädt grubx64.efi aus demselben Verzeichnis; grubnet sucht seine Konfiguration unter /grub/grub.cfg
SHIM=$(ls "$X"/usr/lib/shim/shimx64.efi.signed.latest "$X"/usr/lib/shim/shimx64.efi.signed 2>/dev/null | head -n1)
install -m 0644 "$SHIM" "$TFTP/bootx64.efi"
install -m 0644 "$X/usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed" "$TFTP/grubx64.efi"
install -m 0644 "$X/usr/lib/PXELINUX/lpxelinux.0" "$TFTP/lpxelinux.0"
for f in ldlinux.c32 menu.c32 libutil.c32; do install -m 0644 "$X/usr/lib/syslinux/modules/bios/$f" "$TFTP/$f"; done
# Für die Installer-ISO (UEFI): shim + GRUB für CD/USB (sucht /.disk/info und liest /boot/grub/grub.cfg)
install -d "$TFTP/cd"
install -m 0644 "$SHIM" "$TFTP/cd/bootx64.efi"
install -m 0644 "$X/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed" "$TFTP/cd/grubx64.efi"
rm -rf "$WORK"
echo "ELVIS_PROGRESS 100 fertig"
