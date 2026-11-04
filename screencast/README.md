# Bildschirmübertragung

Mit diesem Addon zeigen Laptops, iPhones und iPads ihren Bildschirm **ohne zusätzliche Software** auf einer Kachel
„Video“, etwa auf der Leinwand oder in der Übersicht.

| Gerät | So wird geteilt |
| --- | --- |
| iPhone, iPad, Mac | AirPlay: Kontrollzentrum → **Bildschirmsynchronisierung** → Empfänger wählen |
| Windows, macOS, Linux | Freigabeseite im Browser öffnen (Edge, Chrome, Firefox) → **Bildschirm teilen** |
| Android | geht ohne App nicht: Android teilt nur per Google Cast, und das verlangt von Google zertifizierte Empfänger |

Jeder darf senden, eine PIN gibt es nicht. Wer zuletzt sendet, ist zu sehen.

## Voraussetzungen

- Ein Docker-Host (amd64 oder arm64), den die **sendenden Geräte und die Bildschirme direkt erreichen**.
- Für AirPlay müssen Apple-Geräte und Docker-Host im **selben Netz** liegen. Apple-Geräte finden Empfänger per mDNS
  (Bonjour), und das geht nicht über Router hinweg.
- Internetzugang des Docker-Hosts einmal beim Installieren (Bau des Images, drei bis acht Minuten).

## 1. Installieren

1. **Installieren** drücken und den Docker-Host wählen.
2. Unter **Empfänger** die Namen eintragen, z. B. `Leinwand, Besprechung`. Unter diesen Namen erscheinen die Empfänger
   auf iPhones und auf der Freigabeseite.
3. Warten, bis das Addon auf „läuft“ steht.

## Zertifikat auf den Rechnern

Die Freigabeseite läuft über HTTPS, denn ohne HTTPS geben Browser den Bildschirm nicht frei. Ihr Zertifikat stellt
ELVIS aus seiner eigenen CA aus und erneuert es selbst.

Damit Browser die Seite ohne Warnung öffnen, die CA **einmal je Rechner** installieren: in ELVIS in der Seitenleiste
**Zertifikat installieren**. Dort steht die Anleitung für Windows, macOS, iOS, Android und Linux. Auf verwalteten
Windows-Rechnern lässt sie sich auch per Gruppenrichtlinie verteilen.

Ohne installierte CA geht es trotzdem: Den Hinweis des Browsers einmal mit **Erweitert → Weiter zu …** übergehen.

## 2. Kachel anlegen

Unter **Bildschirme** oder in der **Übersicht** eine Kachel **Video** anlegen und als Quelle den Empfänger wählen, z. B.
„Leinwand (wartet auf Sender)“.

Solange niemand sendet, zeigt die Kachel, wie man teilt: den AirPlay-Namen, die Adresse der Freigabeseite und dazu einen
QR-Code. Sobald jemand sendet, erscheint das Bild mit dem Namen des Geräts.

## 3. Teilen

- **iPhone/iPad:** Kontrollzentrum öffnen → **Bildschirmsynchronisierung** → Empfänger wählen. Beenden lässt es sich an
  derselben Stelle.
- **Mac:** Menüleiste → Kontrollzentrum → **Bildschirmsynchronisierung**.
- **Windows/Linux/Mac im Browser:** Den QR-Code scannen oder `https://<Docker-Host>:8443` öffnen. Dann Empfänger und Namen wählen,
  **Bildschirm teilen** drücken und den Bildschirm, ein Fenster oder einen Tab auswählen.
  - „Videos und Bewegung bevorzugen“ einschalten, wenn Filme oder Drohnenbilder laufen. Für Folien und Karten
    ausgeschaltet lassen, dann bleibt die Schrift scharf.
  - Ton geht je nach Browser nur beim Teilen eines Tabs oder des ganzen Bildschirms.

## Ports

Alle Container laufen im Netzwerk des Hosts. Die Vorgaben weichen vom NDI-Gateway ab, beide Addons passen also auf
denselben Host.

| Port | Zweck | Erreichbar für |
| --- | --- | --- |
| 8443/tcp | Freigabeseite (HTTPS) | sendende Rechner |
| 7100–7102 tcp+udp (je Empfänger 3 weitere) | AirPlay | Apple-Geräte |
| 5353/udp | mDNS (AirPlay-Suche) | Apple-Geräte |
| 8899/tcp | WebRTC (WHEP) | Bildschirme |
| 8199 udp+tcp | WebRTC-Medien | Bildschirme und sendende Rechner |
| 8898/tcp | Status für ELVIS | ELVIS-Server |

## Störungen

- **iPhone findet den Empfänger nicht:** Steht es im selben WLAN bzw. Netz wie der Docker-Host? Blockiert eine Firewall
  mDNS (5353/udp) oder die AirPlay-Ports?
- **Freigabeseite: „Bildschirmfreigabe geht nur über HTTPS“:** Die Seite mit `https://` öffnen, nicht mit `http://`.
- **Bild bleibt schwarz bei AirPlay:** Kopiergeschützte Inhalte (Netflix, Apple TV+ usw.) überträgt Apple nicht.
- **Bildschirm zeigt AirPlay-Bilder nicht, Browser-Freigaben aber schon:** Unter **Umkodieren** „CPU (x264)“ wählen.
  Das kostet ein bis zwei CPU-Kerne und etwas Verzögerung, läuft dafür in jedem Browser.
