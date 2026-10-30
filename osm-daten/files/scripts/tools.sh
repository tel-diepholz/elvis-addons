# Werkzeuge für die Alpine-Schritte (assets.sh, sources.sh) – per „. /data/addon/scripts/tools.sh“ eingebunden.
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
