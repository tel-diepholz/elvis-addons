# NDI-Gateway: empfängt NDI-Quellen, kodiert sie als H.264 und gibt sie an MediaMTX weiter.
# Die NDI-Bibliothek (proprietär) ist NICHT enthalten – das Addon lädt sie bei der Installation
# nach Zustimmung zur NDI-Lizenz ins Volume und setzt NDI_RUNTIME_DIR_V6.

# 1) NDI-Plugin für GStreamer aus dem offiziellen Quellcode (gst-plugins-rs, MPL-2.0)
FROM rust:1-slim-trixie AS build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates pkg-config \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev && rm -rf /var/lib/apt/lists/*
# 0.14.x passt zu GStreamer 1.26 aus Debian trixie
ARG GST_PLUGINS_RS=0.14.5
RUN git clone --depth 1 --branch "$GST_PLUGINS_RS" https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git /src
WORKDIR /src
RUN cargo build --release -p gst-plugin-ndi && mkdir -p /out && cp target/release/libgstndi.so /out/

# 2) Laufzeit: GStreamer mit x264 (CPU), VA-API (Intel/AMD) und NVENC (NVIDIA, Treiber kommt vom Host)
FROM debian:trixie-slim
RUN sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
      gstreamer1.0-plugins-ugly gstreamer1.0-rtsp \
      intel-media-va-driver-non-free mesa-va-drivers vainfo \
      gstreamer1.0-plugins-base-apps python3 python3-gi gir1.2-gstreamer-1.0 dbus avahi-daemon ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/libgstndi.so /opt/gst-plugins/libgstndi.so
COPY gateway.py /app/gateway.py
ENV GST_PLUGIN_PATH=/opt/gst-plugins \
    NDI_RUNTIME_DIR_V6=/data/ndi/lib \
    NVIDIA_DRIVER_CAPABILITIES=video,compute,utility \
    PYTHONUNBUFFERED=1
ENTRYPOINT ["python3", "/app/gateway.py"]
