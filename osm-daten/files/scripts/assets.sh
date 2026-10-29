#!/bin/sh
# Stile (OSM Bright, ELVIS Dunkel, ELVIS Druck), Sprites und Schriften für tileserver-gl bereitstellen.
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }
# Pakete mit Ausweichspiegeln: dl-cdn.alpinelinux.org (Fastly) ist hinter manchen Firewalls/Proxys gesperrt oder
# zeitweise nicht erreichbar (apk meldet dann „Permission denied“). Pakete sind signiert, daher geht auch http.
apk_add() {
  for repo in https://dl-cdn.alpinelinux.org https://ftp.halifax.rwth-aachen.de http://dl-cdn.alpinelinux.org; do
    sed -i "s#^https\?://[^/]*#$repo#" /etc/apk/repositories
    apk add --no-cache "$@" >/dev/null 2>/tmp/apk.err && return 0
    echo "Paketquelle $repo nicht erreichbar – versuche die nächste"
  done
  cat /tmp/apk.err
  echo "FEHLER: Alpine-Paketquellen nicht erreichbar. Internetzugang des Docker-Hosts prüfen (Firewall/Proxy, DNS)."
  exit 1
}
D=/data/tiles

progress 2 "Werkzeuge installieren"
apk_add curl jq unzip
mkdir -p "$D/styles" "$D/fonts"

# Schriften (OpenMapTiles fonts v2.0, Noto Sans + Metropolis) – nur einmal laden
if [ ! -f "$D/fonts/.openmaptiles-v2.0" ]; then
  progress 5 "Schriften laden (ca. 75 MB)"
  curl -fsSL --retry 3 -o /tmp/fonts.zip https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip
  progress 45 "Schriften entpacken"
  unzip -oq /tmp/fonts.zip -d "$D/fonts"
  rm -f /tmp/fonts.zip
  touch "$D/fonts/.openmaptiles-v2.0"
fi

# Offene OpenMapTiles-Stile auf lokale Daten, Schriften und Sprites umstellen
local_style() { # <id> <repository> <fortschritt>
  progress "$3" "Stil $1 laden"
  mkdir -p "$D/styles/$1"
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/openmaptiles/$2/master/style.json" \
    | jq '.sources.openmaptiles = {"type": "vector", "url": "mbtiles://{openmaptiles}"}
          | .glyphs = "{fontstack}/{range}.pbf"
          | .sprite = "{styleJsonFolder}/sprite"' > "$D/styles/$1/style.json.new"
  mv "$D/styles/$1/style.json.new" "$D/styles/$1/style.json"
  for f in sprite.json sprite.png sprite@2x.json sprite@2x.png; do
    curl -fsSL --retry 3 -o "$D/styles/$1/$f" "https://openmaptiles.github.io/$2/$f"
  done
}
local_style standard osm-bright-gl-style 60
# Eigene Stile (Dark Matter war für die Lagekarte zu dunkel)
progress 90 "Dunkel- und Druckstil übernehmen"
for s in dunkel druck; do
  mkdir -p "$D/styles/$s"
  rm -f "$D/styles/$s"/sprite*
  cp "/data/addon/styles/$s.json" "$D/styles/$s/style.json"
done

# Einfache Anführungszeichen im HTML, damit das JSON unten gültig bleibt
ATTR="<a href='https://openmaptiles.org/'>© OpenMapTiles</a> <a href='https://www.openstreetmap.org/copyright'>© OpenStreetMap-Mitwirkende</a>"
cat > "$D/config.json" <<CONF
{
  "options": { "paths": { "root": "$D", "fonts": "fonts", "styles": "styles", "mbtiles": "" } },
  "styles": {
    "standard": { "style": "standard/style.json", "tilejson": { "attribution": "$ATTR" } },
    "dunkel": { "style": "dunkel/style.json", "tilejson": { "attribution": "$ATTR" } },
    "druck": { "style": "druck/style.json", "tilejson": { "attribution": "$ATTR" } }
  },
  "data": { "openmaptiles": { "mbtiles": "osm.mbtiles" } }
}
CONF
progress 100 "Stile bereit"
