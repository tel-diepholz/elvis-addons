#!/bin/sh
# Richtet das Arbeitsplatz-System im chroot ein (läuft beim Bau des Abbilds, mit Netz).
# Quellen liegen unter /tmp/elvis. Ergebnis: Windows-11-ähnliches Plasma, ELVIS-Anmeldung, keine Updates.
set -eu
S=/tmp/elvis
export DEBIAN_FRONTEND=noninteractive
apt_install() { apt-get install -y --no-install-recommends "$@"; }

# --- Sprache, Tastatur, Zeit ---
sed -i 's/^# *de_DE.UTF-8/de_DE.UTF-8/' /etc/locale.gen
locale-gen de_DE.UTF-8 en_US.UTF-8
printf 'LANG=de_DE.UTF-8\nLANGUAGE=de_DE:de\n' >/etc/default/locale
printf 'XKBMODEL="pc105"\nXKBLAYOUT="de"\nXKBVARIANT="nodeadkeys"\nXKBOPTIONS=""\nBACKSPACE="guess"\n' >/etc/default/keyboard
ln -sf "/usr/share/zoneinfo/${TIMEZONE:-Europe/Berlin}" /etc/localtime
echo "${TIMEZONE:-Europe/Berlin}" >/etc/timezone

# --- Firefox als deb von Mozilla (Ubuntu liefert nur den Snap) ---
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" >/etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
apt-get update
apt_install firefox firefox-l10n-de

# --- Windows-11-Optik: Fluent (vinceliuice, GPL-3.0) für Plasma, GTK, Symbole und Kvantum ---
FLUENT=/tmp/fluent
rm -rf "$FLUENT" && mkdir -p "$FLUENT"
for repo in Fluent-kde Fluent-gtk-theme Fluent-icon-theme; do
  git clone --depth 1 "https://github.com/vinceliuice/$repo.git" "$FLUENT/$repo"
done
# Die Skripte installieren als root nach /usr/share
(cd "$FLUENT/Fluent-kde" && { bash ./install.sh --round || bash ./install.sh; })
(cd "$FLUENT/Fluent-gtk-theme" && { bash ./install.sh -d /usr/share/themes -t default --tweaks round || bash ./install.sh -d /usr/share/themes; })
(cd "$FLUENT/Fluent-icon-theme" && { bash ./install.sh -d /usr/share/icons -r || bash ./install.sh -d /usr/share/icons; })
rm -rf "$FLUENT"
# Tatsächliche Namen nachschlagen (die Skripte hängen je nach Version Varianten an)
pick() { ls -1 "$1" 2>/dev/null | grep -E "$2" | head -n1 | sed 's/\.colors$//'; }
COLORS=$(pick /usr/share/color-schemes '^Fluent.*Light.*\.colors$'); COLORS=${COLORS:-$(pick /usr/share/color-schemes '^Fluent.*\.colors$')}
PLASMA_THEME=$(pick /usr/share/plasma/desktoptheme '^Fluent-round$'); PLASMA_THEME=${PLASMA_THEME:-$(pick /usr/share/plasma/desktoptheme '^Fluent')}
AURORAE=$(pick /usr/share/aurorae/themes '^Fluent(-round)?-light$'); AURORAE=${AURORAE:-$(pick /usr/share/aurorae/themes '^Fluent')}
KVANTUM=$(pick /usr/share/Kvantum '^Fluent(-round)?$'); KVANTUM=${KVANTUM:-$(pick /usr/share/Kvantum '^Fluent')}
ICONS=$(pick /usr/share/icons '^Fluent$'); ICONS=${ICONS:-$(pick /usr/share/icons '^Fluent')}
GTK=$(pick /usr/share/themes '^Fluent(-round)?(-Light)?$'); GTK=${GTK:-$(pick /usr/share/themes '^Fluent')}
echo "Fluent: Farben=$COLORS Plasma=$PLASMA_THEME Fenster=$AURORAE Kvantum=$KVANTUM Symbole=$ICONS GTK=$GTK"

# --- Look-and-Feel „ELVIS Arbeitsplatz“ (Taskleiste unten, zentriert) und Vorgaben für jedes neue Profil ---
install -d /usr/share/plasma/look-and-feel/de.elvis.desktop
cp -a "$S/lookandfeel/." /usr/share/plasma/look-and-feel/de.elvis.desktop/
install -D -m 0644 "$S/start.svg" /usr/share/elvis/start.svg
install -D -m 0644 "$S/wallpaper.svg" /usr/share/wallpapers/ELVIS/contents/images/3840x2160.svg
printf '{"KPlugin":{"Id":"ELVIS","Name":"ELVIS","License":"CC-BY-SA-4.0"}}\n' >/usr/share/wallpapers/ELVIS/metadata.json
install -d /etc/xdg
for f in "$S"/xdg/*; do
  sed -e "s|@COLORS@|$COLORS|g" -e "s|@PLASMA_THEME@|$PLASMA_THEME|g" -e "s|@AURORAE@|$AURORAE|g" -e "s|@ICONS@|$ICONS|g" "$f" >"/etc/xdg/$(basename "$f")"
done
sed -i -e "s|@COLORS@|$COLORS|g" -e "s|@PLASMA_THEME@|$PLASMA_THEME|g" -e "s|@AURORAE@|$AURORAE|g" -e "s|@ICONS@|$ICONS|g" \
  /usr/share/plasma/look-and-feel/de.elvis.desktop/contents/defaults
install -d /etc/xdg/Kvantum
printf '[General]\ntheme=%s\n' "$KVANTUM" >/etc/xdg/Kvantum/kvantum.kvconfig
install -d /etc/gtk-3.0
printf '[Settings]\ngtk-theme-name=%s\ngtk-icon-theme-name=%s\ngtk-font-name=Noto Sans 10\n' "$GTK" "$ICONS" >/etc/gtk-3.0/settings.ini
install -D -m 0644 "$S/elvis.desktop" /usr/share/applications/elvis.desktop

# --- Anmeldung: SDDM-Theme, Dienst, PAM ---
install -d /usr/share/sddm/themes/elvis
cp -a "$S/sddm-theme/." /usr/share/sddm/themes/elvis/
cp "$S/wallpaper.svg" /usr/share/sddm/themes/elvis/background.svg
install -D -m 0644 "$S/sddm.conf" /etc/sddm.conf.d/10-elvis.conf
install -D -m 0755 "$S/elvis-clientd.py" /usr/lib/elvis/elvis-clientd
install -D -m 0755 "$S/pam-check.py" /usr/lib/elvis/pam-check
install -D -m 0644 "$S/elvis-clientd.service" /etc/systemd/system/elvis-clientd.service
install -m 0644 "$S/pam.d-sddm" /etc/pam.d/sddm
install -D -m 0755 "$S/elvis-hinweis.py" /usr/lib/elvis/elvis-hinweis
install -D -m 0644 "$S/elvis-hinweis.desktop" /etc/xdg/autostart/elvis-hinweis.desktop
systemctl enable elvis-clientd.service sddm.service NetworkManager.service cups.service
systemctl set-default graphical.target
# Profilkonten (UID 50000–59999) gehören in diese Gruppen; kein sudo
for g in lpadmin netdev; do getent group "$g" >/dev/null || groupadd -r "$g"; done

# --- Keine Updates: nichts sucht, lädt oder installiert automatisch ---
apt-get purge -y unattended-upgrades update-notifier update-notifier-common update-manager update-manager-core \
  ubuntu-release-upgrader-core ubuntu-release-upgrader-qt plasma-discover plasma-discover-common plasma-discover-backend-fwupd \
  plasma-discover-backend-snap plasma-discover-backend-flatpak packagekit packagekit-tools apport whoopsie popularity-contest \
  snapd motd-news-config ubuntu-advantage-tools ubuntu-pro-client command-not-found plasma-welcome kubuntu-notification-helper 2>/dev/null || true
apt-get autoremove -y --purge
for u in apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service motd-news.timer motd-news.service \
  fwupd-refresh.timer fwupd-refresh.service packagekit.service packagekit-offline-update.service esm-cache.service ua-timer.timer; do
  systemctl mask "$u" >/dev/null 2>&1 || ln -sf /dev/null "/etc/systemd/system/$u"
done
install -m 0644 "$S/99elvis-no-updates" /etc/apt/apt.conf.d/99elvis-no-updates
printf 'Package: snapd\nPin: release a=*\nPin-Priority: -10\n' >/etc/apt/preferences.d/no-snapd
# Paketquellen leeren: das System fragt auch manuell nichts ab (Admin kann sie unter /etc/apt/sources.disabled zurückholen)
install -d /etc/apt/sources.disabled
mv /etc/apt/sources.list.d/* /etc/apt/sources.disabled/ 2>/dev/null || true
[ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.disabled/sources.list
: >/etc/apt/sources.list
rm -rf /var/lib/apt/lists/*

# --- Kleinigkeiten ---
# GRUB: kurz und deutsch, Menü nur mit Umschalt; Notfall-Admin erreicht die Konsole mit Strg+Alt+F3
sed -i -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' \
  -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >>/etc/default/grub
# Kein Absturzbericht, kein Telemetrie-Dienst
rm -f /etc/xdg/autostart/org.kde.discover.notifier.desktop /etc/xdg/autostart/update-notifier.desktop
apt-get clean
rm -rf /var/cache/apt/*.bin /var/log/*.log /var/log/apt/* /tmp/fluent
: >/etc/machine-id
