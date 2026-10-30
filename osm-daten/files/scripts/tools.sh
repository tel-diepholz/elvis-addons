# Werkzeuge für die Job-Schritte (Alpine: assets.sh, sources.sh; Debian: regions.sh) – per „. /data/addon/scripts/tools.sh“ eingebunden.
# Beide Schritte installieren dieselbe Liste, so füllt der erste den Paket-Cache im Volume für den zweiten und für
# alle späteren Läufe; die brauchen dann kein Netz mehr. Ohne Cache: alle Quellen in mehreren Runden mit Pause,
# denn das Netz mancher Hosts fällt minutenweise aus. dl-cdn ist hinter manchen Firewalls/Proxys gesperrt (apk meldet
# dann „Permission denied“); die Pakete sind signiert, daher geht auch http.
APK_CACHE=/data/cache/apk
install_tools() {
  mkdir -p "$APK_CACHE"
  apk add --no-network --cache-dir "$APK_CACHE" curl jq unzip zip >/dev/null 2>&1 && return 0
  for round in 1 2 3; do
    for repo in https://dl-cdn.alpinelinux.org https://ftp.halifax.rwth-aachen.de http://dl-cdn.alpinelinux.org; do
      sed -i "s#^https\?://[^/]*#$repo#" /etc/apk/repositories
      apk add --cache-dir "$APK_CACHE" curl jq unzip zip >/dev/null 2>/tmp/apk.err && return 0
      echo "Paketquelle $repo nicht erreichbar (Runde $round von 3)"
    done
    [ "$round" = 3 ] || sleep 30
  done
  cat /tmp/apk.err
  echo "Namensauflösung dl-cdn.alpinelinux.org:"
  nslookup dl-cdn.alpinelinux.org 2>&1 || true
  echo "FEHLER: Alpine-Paketquellen nicht erreichbar. Internetzugang des Docker-Hosts prüfen (Firewall/Proxy, DNS)."
  exit 1
}

# Debian (regions.sh): gleiches Prinzip. Paketlisten und .debs liegen im Volume; das docker-clean des Images räumt
# nur /var/cache/apt. deb.debian.org läuft wie dl-cdn über Fastly – daher als Ausweichquellen ftp.de.debian.org und
# security.debian.org, die nicht dort liegen.
APT_CACHE=/data/cache/apt
install_debian_tools() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$APT_CACHE/archives/partial" "$APT_CACHE/lists/partial"
  set -- -o Dir::Cache::archives="$APT_CACHE/archives" -o Dir::State::lists="$APT_CACHE/lists" \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=20
  pkgs="curl ca-certificates osmium-tool"
  # Die Listen im Cache sind nach der Quelle benannt, also die zuletzt erfolgreiche Quelle mitnehmen
  sources=/etc/apt/sources.list.d/debian.sources
  [ ! -f "$APT_CACHE/debian.sources" ] || cp "$APT_CACHE/debian.sources" "$sources"
  # shellcheck disable=SC2086
  apt-get "$@" install -y -qq --no-install-recommends --no-download $pkgs >/dev/null 2>&1 && return 0
  for round in 1 2 3; do
    for src in "deb.debian.org/debian deb.debian.org/debian-security" "ftp.de.debian.org/debian security.debian.org/debian-security"; do
      main=${src% *}
      sec=${src#* }
      sed -i "s#^URIs: http://.*/debian\$#URIs: http://$main#; s#^URIs: http://.*/debian-security\$#URIs: http://$sec#" \
        "$sources"
      # Schlägt das Aktualisieren fehl, bleiben die Listen aus dem Cache gültig
      apt-get "$@" update -qq >/dev/null 2>/tmp/apt.err || true
      # shellcheck disable=SC2086
      if apt-get "$@" install -y -qq --no-install-recommends $pkgs >/dev/null 2>>/tmp/apt.err; then
        cp "$sources" "$APT_CACHE/debian.sources"
        return 0
      fi
      echo "Paketquelle ${main%%/*} nicht erreichbar (Runde $round von 3)"
    done
    [ "$round" = 3 ] || sleep 30
  done
  cat /tmp/apt.err
  echo "FEHLER: Debian-Paketquellen nicht erreichbar. Internetzugang des Docker-Hosts prüfen (Firewall/Proxy, DNS)." \
    "Bei 'invalid signature': voller Speicher auf dem Docker-Host (df -h, docker system df), falsche Uhrzeit oder ein Proxy," \
    "der die Antworten verändert."
  exit 1
}
