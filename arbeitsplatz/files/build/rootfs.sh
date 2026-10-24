#!/bin/sh
# Baut das Arbeitsplatz-System als /data/images/rootfs.tar.zst (wird vom Installer auf die Platte entpackt).
set -eu
REL="${RELEASE:-noble}"
MIRROR="http://archive.ubuntu.com/ubuntu"
WORK=/data/work/rootfs
OUT=/data/images
SRC=/data/addon/client

echo "ELVIS_PROGRESS 1 Vorbereiten"
rm -rf "$WORK" /data/work/rootfs.tar
mkdir -p "$WORK" "$OUT"

# Grundsystem mit Kernel, Plasma und Programmen; Feinheiten (Theme, Anmeldung, Update-Sperre) macht setup.sh im chroot
# Ohne Empfehlungen (mmdebstrap) – alles Nötige steht hier ausdrücklich
PKGS="ubuntu-minimal,linux-generic-hwe-24.04,linux-firmware,firmware-sof-signed,initramfs-tools,systemd-sysv,sudo,locales,tzdata,keyboard-configuration,console-setup"
PKGS="$PKGS,grub-efi-amd64-bin,grub-efi-amd64-signed,shim-signed,grub-pc-bin,grub2-common,efibootmgr,os-prober"
PKGS="$PKGS,network-manager,wpasupplicant,openssh-client,ca-certificates,curl,python3,zstd,bash-completion,less,nano"
PKGS="$PKGS,xorg,xserver-xorg-video-all,xserver-xorg-input-all,sddm,kde-config-sddm"
PKGS="$PKGS,kde-plasma-desktop,plasma-desktop,plasma-workspace,kwin-x11,breeze,breeze-icon-theme,plasma-nm,plasma-pa,powerdevil,kscreen,systemsettings"
PKGS="$PKGS,polkit-kde-agent-1,xdg-desktop-portal-kde,kde-cli-tools,kio-extras,pipewire-audio,wireplumber"
PKGS="$PKGS,konsole,dolphin,okular,gwenview,kate,ark,kcalc,kde-spectacle,kdialog"
PKGS="$PKGS,qml-module-qtquick-controls2,qml-module-qtquick-layouts,qml-module-qtgraphicaleffects,qml-module-qtquick-window2"
PKGS="$PKGS,qt5-style-kvantum,qt5-style-kvantum-themes,sassc,git"
PKGS="$PKGS,libreoffice-writer,libreoffice-calc,libreoffice-impress,libreoffice-kf5,libreoffice-l10n-de,hunspell-de-de"
PKGS="$PKGS,cups,cups-browsed,system-config-printer,fonts-noto-core,fonts-noto-color-emoji,fonts-liberation2"
PKGS="$PKGS,language-pack-de,language-pack-kde-de"
for p in ${EXTRA_PACKAGES:-}; do PKGS="$PKGS,$p"; done

echo "ELVIS_PROGRESS 3 Pakete laden und installieren (dauert)"
# Ausgabe als Verzeichnis: setup.sh läuft als Hook mit eingehängtem proc/sys/dev und Netz (Firefox, Fluent-Theme)
mmdebstrap --mode=root --variant=apt --format=directory \
  --components="main restricted universe multiverse" \
  --aptopt='Acquire::Retries "5"' \
  --dpkgopt='path-exclude=/usr/share/doc/*' --dpkgopt='path-include=/usr/share/doc/*/copyright' \
  --include="$PKGS" \
  --setup-hook='echo "ELVIS_PROGRESS 5 Grundsystem"' \
  --essential-hook='echo "ELVIS_PROGRESS 15 Pakete installieren"' \
  --customize-hook='echo "ELVIS_PROGRESS 70 Einrichten"' \
  --customize-hook="mkdir -p \"\$1/tmp/elvis\" && cp -a $SRC/. \"\$1/tmp/elvis/\"" \
  --customize-hook="chroot \"\$1\" env TIMEZONE='${TIMEZONE:-Europe/Berlin}' sh /tmp/elvis/setup.sh" \
  --customize-hook='rm -rf "$1/tmp/elvis"' \
  "$REL" "$WORK" \
  "deb $MIRROR $REL main restricted universe multiverse" \
  "deb $MIRROR $REL-updates main restricted universe multiverse" \
  "deb $MIRROR $REL-security main restricted universe multiverse"

echo "ELVIS_PROGRESS 90 Abbild packen"
# Paketquellen sind nach setup.sh leer; Version für die Anzeige im Installer
date -u +%Y-%m-%dT%H:%MZ > "$WORK/etc/elvis-image"
tar --numeric-owner --xattrs --xattrs-include='*' --acls -C "$WORK" -cf - . | zstd -T0 -10 -q -o /data/work/rootfs.tar.zst.new -f
mv /data/work/rootfs.tar.zst.new "$OUT/rootfs.tar.zst"
du -sb "$WORK" | cut -f1 > "$OUT/rootfs.size"
cp "$WORK/etc/elvis-image" "$OUT/VERSION"
rm -rf "$WORK"
echo "ELVIS_PROGRESS 100 fertig ($(du -h "$OUT/rootfs.tar.zst" | cut -f1))"
