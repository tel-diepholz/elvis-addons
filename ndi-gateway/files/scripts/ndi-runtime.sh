#!/bin/sh
# NDI-Laufzeit (libndi, proprietär) von NDI laden – nur nach ausdrücklicher Zustimmung zur NDI-SDK-Lizenz.
# Aus dem Installationspaket wird nur die Bibliothek für die Rechnerarchitektur entnommen.
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }

if [ "${ACCEPT_LICENSE:-false}" != "true" ]; then
  echo "FEHLER: Der NDI-SDK-Lizenz wurde nicht zugestimmt. In den Addon-Einstellungen „NDI-Lizenzbedingungen akzeptiert“ aktivieren (Lizenz: https://ndi.video/ – NDI SDK License Agreement) und den Job erneut ausführen."
  exit 1
fi

URL=${NDI_SDK_URL:-https://downloads.ndi.tv/SDK/NDI_SDK_Linux/Install_NDI_SDK_v6_Linux.tar.gz}
case "$(uname -m)" in
  x86_64) ARCH=x86_64-linux-gnu ;;
  aarch64) ARCH=aarch64-rpi4-linux-gnueabi ;;
  *) echo "FEHLER: Architektur $(uname -m) wird nicht unterstützt"; exit 1 ;;
esac

progress 1 "Werkzeuge installieren"
apk add --no-cache curl >/dev/null

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
progress 5 "NDI SDK laden"
curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 15 -o "$W/sdk.tar.gz" "$URL"
progress 60 "Entpacken"
tar -xzf "$W/sdk.tar.gz" -C "$W"
INSTALLER=$(ls "$W"/Install_NDI_SDK_*_Linux.sh | head -n1)
# Das Installationsskript fragt die Lizenz interaktiv ab – zugestimmt wurde oben; das angehängte Archiv direkt entpacken
LINE=$(awk '/^__NDI_ARCHIVE_BEGIN__/ { print NR + 1; exit 0 }' "$INSTALLER")
mkdir -p "$W/sdk"
tail -n +"$LINE" "$INSTALLER" | tar -xz -C "$W/sdk"
SDK=$(ls -d "$W"/sdk/NDI* | head -n1)
LIB=$(ls "$SDK/lib/$ARCH"/libndi.so.6.* | head -n1)

progress 85 "Bibliothek ablegen"
mkdir -p /data/ndi/lib
cp "$LIB" /data/ndi/lib/
cp "$SDK/licenses/libndi_licenses.txt" /data/ndi/ 2>/dev/null || true
(cd /data/ndi/lib && ln -sf "$(basename "$LIB")" libndi.so.6 && ln -sf libndi.so.6 libndi.so)
head -n1 "$SDK/Version.txt" > /data/ndi/version.txt 2>/dev/null || true
progress 100 "NDI-Laufzeit bereit ($(cat /data/ndi/version.txt 2>/dev/null || basename "$LIB"))"
