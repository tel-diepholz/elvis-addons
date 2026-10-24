#!/bin/sh
# Läuft nach dem Entpacken im chroot des installierten Systems (Installer, mit Netz zum Addon).
# Bringt Korrekturen am Client-System ohne neuen Bau des Abbilds: aktuelle Dateien vom Addon und Einstellungen.
# ADDON = http://<Docker-Host>:<Port> des Addons. Fehler beim Laden lassen die eingebaute Fassung stehen.
set -u
ADDON="${ADDON:?}"

# NetworkManager verwaltet auch Kabelanschlüsse (Ubuntu überlässt sie sonst netplan/networkd – ohne Adresse)
install -d /etc/NetworkManager/conf.d /etc/netplan
: > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
printf 'network:\n  version: 2\n  renderer: NetworkManager\n' > /etc/netplan/01-network-manager-all.yaml
chmod 0600 /etc/netplan/01-network-manager-all.yaml

fetch() {
  src=$1 dst=$2 mode=$3
  if curl -fsS --retry 3 -o "$dst.new" "$ADDON/client/$src"; then
    install -m "$mode" "$dst.new" "$dst" && rm -f "$dst.new" && echo "aktualisiert: $dst"
  else
    rm -f "$dst.new"; echo "nicht geladen (eingebaute Fassung bleibt): $src"
  fi
}
fetch elvis-clientd.py /usr/lib/elvis/elvis-clientd 0755
fetch pam-check.py /usr/lib/elvis/pam-check 0755
fetch elvis-hinweis.py /usr/lib/elvis/elvis-hinweis 0755
fetch pam.d-sddm /etc/pam.d/sddm 0644
fetch pam-unlock.py /usr/lib/elvis/pam-unlock 0755
fetch pam.d-kde /etc/pam.d/kde 0644
fetch sddm-theme/Main.qml /usr/share/sddm/themes/elvis/Main.qml 0644
exit 0
