# Werkzeuge zum Bauen der Ubuntu-Abbilder (Arbeitsplatz-System, Installer, Netzwerkstart)
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      mmdebstrap ubuntu-keyring squashfs-tools zstd curl ca-certificates gnupg xz-utils \
 && rm -rf /var/lib/apt/lists/*
