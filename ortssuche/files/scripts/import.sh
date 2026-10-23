#!/bin/bash
# Erstimport der Ortssuche im Nominatim-Image (mediagis/nominatim): OSM-Daten laden, in PostgreSQL importieren,
# indizieren und als fertig markieren. Danach startet ELVIS den Suchdienst, der sich über die Replikation
# selbst aktuell hält. Ein erneuter Lauf ändert nichts – sonst liefen zwei Datenbanken auf demselben Volume.
# Zum Neuaufbau (z. B. andere Region) das Addon mit „Daten löschen“ deinstallieren und neu installieren.
set -euo pipefail
exec 3>&1
progress() { echo "ELVIS_PROGRESS $1 $2" >&3; }

PG=/var/lib/postgresql/16/main
MARKER=$PG/import-finished

if [ -f "$MARKER" ]; then
  echo "Suchdaten sind bereits importiert ($(cat "$MARKER" 2>/dev/null || echo 'Datum unbekannt'))."
  echo "Aktualisierungen laufen im Suchdienst über die Replikation, sobald Internet verfügbar ist."
  progress 100 "Bereits importiert"
  exit 0
fi

free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

# Platzbedarf grob aus der Größe der OSM-Daten: Datenbank (je nach Stil) plus Download im Container
if ! headers=$(curl -fsSIL --retry 3 "$PBF_URL" 2>&1); then
  echo "FEHLER: OSM-Daten nicht abrufbar ($PBF_URL): $(echo "$headers" | tr -d '\r' | grep '^HTTP' | tail -n1)"
  exit 1
fi
size=$(echo "$headers" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -n1)
size_mb=$((size / 1048576))
case "${IMPORT_STYLE:-full}" in
  admin | street) factor=8 ;;
  address) factor=16 ;;
  *) factor=22 ;;
esac
need_db=$((size_mb * factor + 2048))
need_tmp=$((size_mb + 1024))
echo "OSM-Daten: $size_mb MB, Datenbank (Stil ${IMPORT_STYLE:-full}) etwa $need_db MB, frei $(free_mb "$PG") MB"
if [ "$(free_mb "$PG")" -lt "$need_db" ]; then
  echo "FEHLER: Zu wenig Speicher für die Datenbank: etwa $need_db MB nötig, $(free_mb "$PG") MB frei. Kleinere Region oder Importstil „Adressen“ wählen, oder Platz schaffen."
  exit 1
fi
if [ "$(free_mb /nominatim)" -lt "$need_tmp" ]; then
  echo "FEHLER: Zu wenig Speicher im Docker-Speicher für den Download: etwa $need_tmp MB nötig, $(free_mb /nominatim) MB frei ('docker system prune' hilft oft)."
  exit 1
fi

progress 1 "Import vorbereiten"
# Wie start.sh des Images: Konfiguration schreiben und Benutzer anlegen, dann der eigentliche Import
/app/config.sh
id nominatim >/dev/null 2>&1 || useradd -m -p "${NOMINATIM_PASSWORD:-}" nominatim

/app/init.sh
date -Iseconds > "$MARKER"
progress 100 "Import abgeschlossen"
