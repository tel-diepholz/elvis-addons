# CUPS mit gängigen Treibern. Moderne Netzwerkdrucker brauchen keinen Treiber (IPP Everywhere / AirPrint).
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      cups cups-client cups-bsd cups-filters cups-ipp-utils ghostscript poppler-utils \
      avahi-daemon curl iproute2 \
      printer-driver-gutenprint printer-driver-hpcups printer-driver-brlaser printer-driver-splix printer-driver-foo2zjs printer-driver-escpr \
 && rm -rf /var/lib/apt/lists/* \
 # Vorgaben sichern: /etc/cups liegt später im Volume
 && cp -a /etc/cups /etc/cups.dist
COPY entrypoint.sh /usr/local/bin/elvis-cups
# Gastdrucker: eigener CUPS im Gastnetz, Ankündigung per Bonjour, Weitergabe der PDFs an ELVIS
COPY guest.sh /usr/local/bin/elvis-cups-guest
COPY gastdrucker.ppd /usr/share/elvis/gastdrucker.ppd
COPY backend-elvis /usr/lib/cups/backend/elvis
# 0700: CUPS startet das Backend als root – es liest die Absenderadresse aus der Auftragsdatei
RUN chmod 0700 /usr/lib/cups/backend/elvis
EXPOSE 631
ENTRYPOINT ["sh", "/usr/local/bin/elvis-cups"]
