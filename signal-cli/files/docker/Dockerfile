# signal-cli (native GraalVM-Fassung, keine JRE nötig) und nginx als Token-Prüfung davor
FROM debian:bookworm-slim

# Neue Fassung: Version hier und im Manifest erhöhen (Signal sperrt alte signal-cli nach einigen Monaten)
ARG SIGNAL_CLI_VERSION=0.14.9

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl nginx-light gettext-base tini \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
     | tar xz -C /usr/local/bin \
  && chmod +x /usr/local/bin/signal-cli \
  && signal-cli --version \
  && useradd --system --home /var/lib/signal-cli --shell /usr/sbin/nologin signal \
  && mkdir -p /var/lib/signal-cli && chown signal /var/lib/signal-cli

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
