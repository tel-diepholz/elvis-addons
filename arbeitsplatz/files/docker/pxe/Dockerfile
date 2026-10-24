# Netzwerkstart: dnsmasq (ProxyDHCP + TFTP) und nginx (Installer, Abbild, Konfiguration)
FROM alpine:3.20
RUN apk add --no-cache dnsmasq nginx openssl iproute2
COPY entrypoint.sh /usr/local/bin/elvis-pxe
COPY grub.cfg.in pxelinux.cfg.in /usr/share/elvis/
COPY nginx.conf /etc/nginx/nginx.conf
ENTRYPOINT ["sh", "/usr/local/bin/elvis-pxe"]
