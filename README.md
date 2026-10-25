# ELVIS-Addons

Addons für [ELVIS](https://github.com/tel-diepholz/elvis) – das EinsatzLeitwagen Verwaltungs- und
InformationsSystem. ELVIS installiert sie als Docker-Container auf den Servern im Fahrzeug.

| Addon | Zweck |
|---|---|
| [`osm-daten`](osm-daten/addon.yaml) | Offline-Kartendaten aus OpenStreetMap in einem Rutsch: Kacheln (Planetiler + tileserver-gl, Standard/Dunkel/Druck), Ortssuche mit Umrissen (Nominatim), Routing (Valhalla) und Overpass – mehrere Geofabrik-Regionen, keine automatische Aktualisierung, Regionen jederzeit ergänzbar. Ersetzt `kartenserver` und `ortssuche` (vorher deinstallieren) |
| [`collabora`](collabora/addon.yaml) | Office-Dokumente und Vorlagen im Browser bearbeiten (Collabora Online, WOPI), auch gemeinsam |
| [`druckserver`](druckserver/addon.yaml) | Drucker im Fahrzeug über CUPS (LAN oder USB), optional Gastdrucker im Gastnetz für iPhone (AirPrint), Android und Windows ohne App |
| [`arbeitsplatz`](arbeitsplatz/addon.yaml) | Notebooks per PXE als ELVIS-Arbeitsplatz installieren (Ubuntu, KDE Plasma im Windows-11-Stil), Anmeldung mit ELVIS-Benutzern und PIN, Profil je Einsatz, keine Updates |
| [`ndi-gateway`](ndi-gateway/addon.yaml) | NDI-Quellen im Browser: GStreamer → H.264 → MediaMTX → WebRTC, Encoder CPU/VA-API/NVENC |
| [`hello`](hello/addon.yaml) | Kleines Beispiel zum Ausprobieren der Addon-Verwaltung |

## Einbindung in ELVIS

- **Offline:** ELVIS enthält dieses Repository als Git-Submodul unter `addons/` (eingebautes Repository).
- **Online:** Neue Addon-Versionen erscheinen ohne ELVIS-Update, wenn die Basis-URL als Online-Repository eingetragen ist
  (im Docker-Image von ELVIS voreingestellt):

  ```json
  "addons": { "repositories": ["https://raw.githubusercontent.com/tel-diepholz/elvis-addons/main"] }
  ```

  Gibt es ein Addon in beiden Quellen, gewinnt die höhere Version, bei gleicher Version die eingebaute.

## Aufbau

```
repository.yaml          Name und Liste der Addon-Verzeichnisse
<addon>/addon.yaml       Manifest: Optionen (daraus entsteht das Formular), Container, Jobs, provides, builds
<addon>/files/…          Dateien, die ins Volume kopiert oder als Build-Kontext genutzt werden
```

Eine neue Addon-Version wird über `version` im Manifest veröffentlicht. Bei Addons mit `builds` baut ELVIS das Image
dann auf dem Host neu. Das Manifest-Format ist im README von ELVIS beschrieben.

## Lizenz

[MIT](LICENSE). Addons laden Software Dritter erst bei der Installation und unter deren eigenen Lizenzen, z. B. die
NDI-Laufzeit (NDI SDK License Agreement, nur nach ausdrücklicher Zustimmung). Die Daten der Ortssuche stammen aus
OpenStreetMap (ODbL).
