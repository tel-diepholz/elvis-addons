# Empfänger der Bildschirmübertragung: UxPlay (AirPlay, GPL-3.0) aus dem Quellcode, GStreamer zum Weiterleiten an
# MediaMTX und ein kleiner Python-Dienst für Status, Freigabeseite (HTTPS) und WHIP-Proxy.
FROM debian:trixie-slim

# UxPlay ab 1.73 kann das entschlüsselte H.264 per RTP weiterreichen (-vrtp) statt es selbst anzuzeigen
ARG UXPLAY=v1.73.7

RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
      gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-rtsp \
      intel-media-va-driver-non-free mesa-va-drivers \
      libssl-dev libplist-dev libavahi-compat-libdnssd-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      dbus avahi-daemon python3 openssl ca-certificates \
      git cmake build-essential pkg-config \
 && git clone --depth 1 --branch "$UXPLAY" https://github.com/FDH2/UxPlay.git /src/uxplay \
 && cmake -S /src/uxplay -B /src/uxplay/build -DNO_X11_DEPS=ON -DNO_MARCH_NATIVE=ON -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/uxplay/build -j"$(nproc)" \
 && install -m 0755 /src/uxplay/build/uxplay /usr/local/bin/uxplay \
 && rm -rf /src \
 && apt-get purge -y --auto-remove git cmake build-essential \
 && rm -rf /var/lib/apt/lists/*

COPY receiver.py share.html /app/
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "/app/receiver.py"]
