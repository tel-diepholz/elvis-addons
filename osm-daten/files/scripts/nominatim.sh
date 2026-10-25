#!/bin/bash
# Ortssuche im Nominatim-Image (mediagis/nominatim) auf den Stand der gewählten Regionen bringen:
# - erster Lauf, Region abgewählt oder Region neu geladen → komplette Datenbank aus /data/work/input.osm.pbf
# - nur Regionen dazugekommen → diese mit „nominatim add-data“ nachladen (Minuten statt Stunden für Deutschland)
# - nichts geändert → nichts tun
# Der Suchdienst ist während dieses Schritts angehalten (stopContainers), beide nutzen dieselbe Datenbank.
set -euo pipefail
exec 3>&1
progress() { echo "ELVIS_PROGRESS $1 $2" >&3; }

PG=/var/lib/postgresql/16/main
MARKER=$PG/import-finished
# Stand der importierten Regionen (Format wie /data/work/stamp: Region Größe Zeitstempel)
STAMP=$PG/elvis-stamp
W=/data/work

if [ -f "$MARKER" ] && cmp -s "$W/stamp" "$STAMP"; then
  echo "Regionen unverändert – Suchdaten bleiben ($(cat "$MARKER"))."
  progress 100 "Ortssuche aktuell"
  exit 0
fi

# Neue Regionen = Zeilen im aktuellen Stand, die im importierten fehlen. Nur wenn alle bisherigen unverändert
# dabei sind, reicht das Nachladen.
added=()
full=true
if [ -f "$MARKER" ] && [ -f "$STAMP" ]; then
  if [ -z "$(comm -13 <(sort "$W/stamp") <(sort "$STAMP"))" ]; then
    full=false
    while read -r region _; do added+=("$region"); done < <(comm -23 <(sort "$W/stamp") <(sort "$STAMP"))
  fi
fi

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }
case "${IMPORT_STYLE:-full}" in
  admin | street) factor=8 ;;
  address) factor=16 ;;
  *) factor=22 ;;
esac
size_mb=0
if $full; then
  size_mb=$(($(stat -c %s "$W/input.osm.pbf") / 1048576))
else
  for r in "${added[@]}"; do size_mb=$((size_mb + $(stat -c %s "/data/osm/$(echo "$r" | tr '/' '_').osm.pbf") / 1048576)); done
fi
need_db=$((size_mb * factor + 2048))
# Beim Neuaufbau wird die alte Datenbank erst gelöscht – ihr Platz zählt mit
have=$(free_mb "$PG")
if $full && [ -f "$MARKER" ]; then have=$((have + $(du -sm "$PG" | cut -f1))); fi
echo "Neu zu importieren: $size_mb MB OSM-Daten, Datenbank (Stil ${IMPORT_STYLE:-full}) etwa $need_db MB, verfügbar $have MB"
if [ "$have" -lt "$need_db" ]; then
  echo "FEHLER: Zu wenig Speicher für die Ortssuche: etwa $need_db MB nötig, $have MB verfügbar. Weniger Regionen oder Importstil „Adressen“ wählen, oder Platz schaffen."
  exit 1
fi

progress 1 "Import vorbereiten"
# Wie start.sh des Images: Konfiguration schreiben und Benutzer anlegen
/app/config.sh
id nominatim >/dev/null 2>&1 || useradd -m -p "${NOMINATIM_PASSWORD:-}" nominatim

if $full; then
  echo "Kompletter Import aller Regionen"
  # Ohne Stand macht ein abgebrochener Import beim nächsten Lauf wieder komplett weiter
  rm -f "$STAMP"
  # init.sh löscht eine vorhandene Datenbank „nominatim“ selbst und importiert $PBF_PATH
  /app/init.sh
else
  echo "Regionen nachladen: ${added[*]}"
  chown -R nominatim:nominatim "$PROJECT_DIR"
  service postgresql start
  trap 'service postgresql stop || true' EXIT
  cd "$PROJECT_DIR"
  threads=${THREADS:-$(nproc)}
  i=0
  for r in "${added[@]}"; do
    progress $((5 + i * 80 / ${#added[@]})) "$r importieren"
    sudo -E -u nominatim nominatim add-data --file "/data/osm/$(echo "$r" | tr '/' '_').osm.pbf" --threads "$threads"
    i=$((i + 1))
  done
  progress 85 "Indizieren"
  sudo -E -u nominatim nominatim index --threads "$threads"
  progress 95 "Statistik"
  sudo -E -u nominatim psql -d nominatim -c "ANALYZE"
fi

cp "$W/stamp" "$STAMP"
date -Iseconds > "$MARKER"
progress 100 "Ortssuche fertig"
