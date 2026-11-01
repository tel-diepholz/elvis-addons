# Signal (signal-cli)

Mit diesem Addon sendet und empfängt ELVIS **Signal-Nachrichten**. Sie erscheinen unter **Nachrichten** zusammen mit
SMS und den anderen Messengern. Das Addon betreibt [signal-cli](https://github.com/AsamK/signal-cli) als Dienst auf
einem Docker-Host. ELVIS findet den Dienst von selbst.

## Voraussetzungen

- Ein Docker-Host mit **x86_64 (amd64)**. signal-cli gibt es als native Fassung nur dafür.
- Internetzugang des Docker-Hosts: einmal beim Installieren (GitHub, rund 120 MB), danach dauerhaft zu den
  Signal-Servern.
- Eine **Rufnummer** für Signal. Dafür gibt es zwei Wege (siehe unten):
  - eine Nummer, die schon in der Signal-App eines Handys läuft (ELVIS wird verknüpftes Gerät),
  - eine eigene Nummer nur für das Fahrzeug, z. B. die SIM im GSM-Gateway.

## 1. Addon installieren

1. **Installieren** drücken, Docker-Host wählen. Der Port (Vorgabe 8087) muss auf dem Host frei sein.
2. Beim ersten Mal baut ELVIS das Image (ein bis drei Minuten). Danach steht das Addon auf „läuft“.

## 2. Modul Signal einschalten

1. **Einstellungen → Fahrzeugmodule → Signal** aufklappen und **Modul aktiv** einschalten.
2. Als **Treiber** „signal-cli (Addon)“ wählen. ELVIS nutzt dann dieses Addon, Adresse und Token stellt es selbst ein.
3. **Übernehmen**. Unter den Einstellungen erscheint die Karte **Signal-Konto** mit „Einrichtung ausstehend“.

## 3. Rufnummer hinterlegen

Die Rufnummer richtest du in der Karte **Signal-Konto** ein. Eine neue Nummer legt das Feld „Rufnummer des Kontos“ in
den Moduleinstellungen nicht an.

### Weg A: Als verknüpftes Gerät koppeln (empfohlen)

Für eine Nummer, die schon in der Signal-App eines Handys läuft. Das Handy bleibt das Hauptgerät, ELVIS schreibt mit
dessen Nummer.

1. **Als verknüpftes Gerät koppeln** drücken. ELVIS zeigt einen QR-Code.
2. Am Handy in Signal: **Einstellungen → Verknüpfte Geräte → Gerät hinzufügen** und den QR-Code scannen.
3. Nach ein paar Sekunden steht in der Karte „verbunden“ und die Nummer.

Unter „Verknüpfte Geräte“ heißt ELVIS so, wie unter „Gerätename beim Koppeln“ eingetragen (Vorgabe „ELVIS“).
**Wichtig:** Signal trennt verknüpfte Geräte, wenn das Handy länger als etwa 30 Tage nicht online war. Dann neu
koppeln.

### Weg B: Eigene Nummer registrieren

Für eine Nummer nur für das Fahrzeug. **Die Nummer lässt sich danach in keiner Signal-App auf einem Handy mehr
nutzen.**

1. Captcha lösen: [signalcaptchas.org/registration/generate.html](https://signalcaptchas.org/registration/generate.html)
   öffnen und das Captcha lösen. Danach erscheint der Link **„Open Signal“**. Ihn mit Rechtsklick → *Link-Adresse
   kopieren* kopieren. Er beginnt mit `signalcaptcha://`. Das Captcha gilt nur wenige Minuten.
2. In der Karte **Signal-Konto** die **Rufnummer** mit Ländervorwahl eintragen (z. B. `+49 170 1234567`), das
   **Captcha** einfügen und **Registrieren** drücken. Kann die Nummer keine SMS empfangen (Festnetz), „Code per Anruf
   statt SMS“ ankreuzen.
3. Signal schickt einen **sechsstelligen Code** per SMS. Steckt die SIM im GSM-Gateway von ELVIS, steht die SMS unter
   **Nachrichten**.
4. Den Code eintragen und **Bestätigen**. Das Feld „PIN der Registrierungssperre“ nur ausfüllen, wenn die Nummer früher
   schon mit Registrierungssperre bei Signal registriert war.
5. In der Karte steht „verbunden“ und die Nummer.

## 4. Ausprobieren

- Unter **Nachrichten → Neue Nachricht** eine Mobilnummer eintragen und als Kanal **Signal** wählen.
- Unter **Kontakte** zeigt ein Signal-Symbol an der Rufnummer, wer Signal nutzt. ELVIS prüft das für die Mobilnummern
  der Kontakte selbst.
- Bilder gehen in beide Richtungen. Standorte schickt ELVIS als Kartenlink und erkennt Kartenlinks in eingehenden
  Nachrichten als Standort.
- Nur Einzelchats: Nachrichten aus Gruppen übernimmt ELVIS nicht.

## Updates

Signal sperrt alte signal-cli-Versionen nach einigen Monaten. Neue Fassungen kommen als neue Version dieses Addons.
Steht beim Addon **Aktualisieren**, bitte zeitnah aktualisieren. Konto und Schlüssel bleiben dabei erhalten.

## Daten und Sicherheit

- Konto, Schlüssel und Kontakte von signal-cli liegen im Volume **data** des Addons. Bei **Deinstallieren** mit „Auch
  die Daten löschen“ ist das Konto weg, und Weg A oder B ist erneut nötig. Bei Weg B kann die Nummer dann in Signal
  gesperrt sein (Registrierungssperre).
- Die Schnittstelle von signal-cli hat keine eigene Anmeldung. Das Addon lässt sie deshalb nur im Container lauschen und
  prüft davor ein Token, das nur ELVIS kennt. Wer den Port erreicht, kommt ohne Token nicht weiter.
- Bestätigungscodes, PIN und Captcha landen nicht im Bedienprotokoll von ELVIS.

## Fehler beheben

| Meldung | Abhilfe |
| --- | --- |
| Karte zeigt „gestört“ mit „signal-cli nicht erreichbar“ | Läuft das Addon? Ist der Port auf dem Docker-Host vom ELVIS-Server aus erreichbar (Firewall)? |
| „Kein signal-cli: Addon … installieren und starten“ | Das Addon ist nicht installiert oder gestoppt. Unter **Addons** starten. |
| „signal-cli lehnt das Token ab“ | Addon neu starten. |
| „Signal verlangt ein Captcha“ / Registrieren schlägt fehl | Neues Captcha holen (gilt nur kurz) und sofort registrieren. |
| Code kommt nicht an | Einige Minuten warten, dann erneut registrieren, ggf. mit „Code per Anruf“. |
| „Koppeln abgebrochen“ | Der QR-Code war zu lange offen. Erneut auf „Als verknüpftes Gerät koppeln“ drücken. |
| Nach einem Update startet das Addon nicht | Log des Containers ansehen. Meldet signal-cli eine zu alte Version, auf die neueste Addon-Version aktualisieren. |

Mehr zum Modul: Dokumentation von ELVIS unter `docs/fahrzeugmodule/signal-cli.md` und `docs/funktionen/nachrichten.md`.
