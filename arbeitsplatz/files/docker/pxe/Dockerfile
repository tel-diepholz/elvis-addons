# Netzwerkstart: dnsmasq (ProxyDHCP + TFTP) und nginx (Installer, Abbild, Konfiguration)
FROM alpine:3.20
# xorriso, dosfstools, mtools, syslinux: Installer-ISO (BIOS + UEFI, als CD oder USB-Stick)
RUN apk add --no-cache dnsmasq nginx openssl iproute2 xorriso dosfstools mtools syslinux
COPY entrypoint.sh /usr/local/bin/elvis-pxe
COPY grub.cfg.in pxelinux.cfg.in iso-grub.cfg.in isolinux.cfg.in /usr/share/elvis/
COPY nginx.conf /etc/nginx/nginx.conf
ENTRYPOINT ["sh", "/usr/local/bin/elvis-pxe"]
