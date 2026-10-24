# apt-Cache für Updates der Arbeitsplätze: Ubuntu-Pakete werden einmal geladen und an alle Notebooks verteilt.
# HTTPS (Firefox von Mozilla, Firmware vom LVFS) geht ungecacht per CONNECT durch – nur zu diesen Zielen.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-cacher-ng ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY acng.conf /etc/apt-cacher-ng/acng.conf
COPY entrypoint.sh /usr/local/bin/elvis-aptcache
EXPOSE 3142
ENTRYPOINT ["sh", "/usr/local/bin/elvis-aptcache"]
