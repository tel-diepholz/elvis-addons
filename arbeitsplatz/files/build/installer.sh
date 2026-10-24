#!/bin/sh
# Baut den Installer: kleines Live-System (live-boot, lädt sich per HTTP in den RAM) mit Kernel und initrd für TFTP.
set -eu
REL="${RELEASE:-noble}"
MIRROR="http://archive.ubuntu.com/ubuntu"
WORK=/data/work/installer
OUT=/data/images/installer
TFTP=/data/tftp/installer
SRC=/data/addon/installer

echo "ELVIS_PROGRESS 1 Vorbereiten"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT" "$TFTP"

PKGS="linux-image-generic-hwe-24.04,linux-firmware,initramfs-tools,live-boot,live-boot-initramfs-tools,systemd-sysv,systemd-resolved,udev,kmod"
PKGS="$PKGS,whiptail,gdisk,parted,dosfstools,e2fsprogs,util-linux,zstd,curl,ca-certificates,iproute2,pciutils,usbutils,lvm2,ncurses-term,console-setup,kbd"

echo "ELVIS_PROGRESS 5 Pakete laden und installieren"
mmdebstrap --mode=root --variant=minbase --format=directory \
  --components="main restricted universe multiverse" \
  --aptopt='Acquire::Retries "5"' \
  --dpkgopt='path-exclude=/usr/share/doc/*' --dpkgopt='path-exclude=/usr/share/man/*' --dpkgopt='path-exclude=/usr/share/locale/*' \
  --include="$PKGS" \
  --customize-hook="install -m 0755 $SRC/elvis-install \"\$1/usr/local/sbin/elvis-install\"" \
  --customize-hook="install -m 0644 $SRC/elvis-install.service \"\$1/etc/systemd/system/elvis-install.service\"" \
  --customize-hook="install -D -m 0644 $SRC/20-wired.network \"\$1/etc/systemd/network/20-wired.network\"" \
  --customize-hook='chroot "$1" systemctl enable elvis-install.service systemd-networkd.service systemd-resolved.service' \
  --customize-hook='chroot "$1" systemctl mask getty@tty1.service' \
  --customize-hook='echo elvis-installer > "$1/etc/hostname"' \
  --customize-hook='printf "KEYMAP=de-latin1-nodeadkeys\n" > "$1/etc/vconsole.conf"' \
  --customize-hook='chroot "$1" passwd -l root' \
  --customize-hook='chroot "$1" update-initramfs -u -k all' \
  "$REL" "$WORK" \
  "deb $MIRROR $REL main restricted universe multiverse" \
  "deb $MIRROR $REL-updates main restricted universe multiverse" \
  "deb $MIRROR $REL-security main restricted universe multiverse"

echo "ELVIS_PROGRESS 80 Kernel und squashfs"
# Ubuntu legt Kernel und initrd nur für root lesbar ab (0600) – TFTP und nginx laufen ohne root
install -m 0644 "$WORK/boot/vmlinuz" "$TFTP/vmlinuz.new" && mv "$TFTP/vmlinuz.new" "$TFTP/vmlinuz"
install -m 0644 "$WORK/boot/initrd.img" "$TFTP/initrd.img.new" && mv "$TFTP/initrd.img.new" "$TFTP/initrd.img"
echo "Kernel $(du -h "$TFTP/vmlinuz" | cut -f1), initrd $(du -h "$TFTP/initrd.img" | cut -f1)"
rm -f "$OUT/filesystem.squashfs.new"
mksquashfs "$WORK" "$OUT/filesystem.squashfs.new" -comp zstd -e boot -noappend -quiet
mv "$OUT/filesystem.squashfs.new" "$OUT/filesystem.squashfs"
rm -rf "$WORK"
echo "ELVIS_PROGRESS 100 fertig"
