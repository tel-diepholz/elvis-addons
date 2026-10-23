#!/bin/sh
# Stile (OSM Bright, Dark Matter, ELVIS Druck), Sprites und Schriften für tileserver-gl bereitstellen.
set -eu
progress() { echo "ELVIS_PROGRESS $1 $2"; }
D=/data

progress 2 "Werkzeuge installieren"
apk add --no-cache curl jq unzip >/dev/null
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
local_style dunkel dark-matter-gl-style 75

progress 90 "Druckstil übernehmen"
mkdir -p "$D/styles/druck"
cp "$D/addon/styles/druck.json" "$D/styles/druck/style.json"

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
