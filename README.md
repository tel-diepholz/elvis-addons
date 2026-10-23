# ELVIS-Addons

Addons für [ELVIS](https://github.com/tel-diepholz/elvis) – das EinsatzLeitwagen Verwaltungs- und
InformationsSystem. ELVIS installiert sie als Docker-Container auf den Servern im Fahrzeug.

| Addon | Zweck |
|---|---|
| [`kartenserver`](kartenserver/addon.yaml) | Eigene Kartenkacheln aus OpenStreetMap (Planetiler + tileserver-gl), offline nutzbar, mit Standard-, Dunkel- und Druckstil |
| [`ortssuche`](ortssuche/addon.yaml) | Ortssuche und Ortsumrisse für die Karte ohne Internet: Nominatim mit OSM-Daten von Geofabrik (Deutschland ca. 100 GB, Import 8–12 h), aktuell über Replikation |
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
