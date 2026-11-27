# zollsoft Anrufbeantworter

| Teil | Ordner | Zweck |
|---|---|---|
| **iPhone-App** | [`ios/`](ios/README.md) | Status/Urlaub/Vertretung, Aussprache-Prüfung, **Aufnahme der eigenen Ansage-Bausteine**. Funktioniert allein über die Mailbox oder zusammen mit dem Cloud-Anrufbeantworter. |
| **Cloud-Anrufbeantworter** | `src/`, `public/`, `stimme/` | Nimmt per Rufumleitung vom iPhone ab: Ansage aus **echten Aufnahmen**, erkannte Anrufer werden mit Namen begrüßt (Qto/ZSWork), Taste 1 verbindet zur Vertretung, Rückrufliste. |

Das Fachkonzept steht in **[KONZEPT.md](KONZEPT.md)**.

## Klang: echte Aufnahmen, KI nur für den Namen

Synthetische Stimmen klingen am Telefon schnell abschreckend. Deshalb besteht die Ansage aus **echten Aufnahmen**. Jeder Mitarbeiter spricht seine Bausteine einmal ein, in der iPhone-App oder im Browser. Alternativ nimmt ein Profisprecher sie auf.

```
„Guten Tag, Frau Dr. Schneider!“                    ← KI, in der Stimme der Aufnahmen (nur bei erkannten Anrufern)
„Sie sind verbunden mit dem Anschluss von …“        ← Aufnahme
„Ich bin gerade in einer Online-Präsentation …“     ← Aufnahme
„In dringenden Fällen … Thomas Müller …“            ← Aufnahme
„Bitte hinterlassen Sie nach dem Signalton …“       ← Aufnahme
```

- **Bausteine:** Der Server leitet aus Profil, Status, Vertretungen und Regeln ab, welche Sätze gebraucht werden. Die Liste zeigt jeweils, was fehlt. Ändert sich ein Text (z. B. die Funktion), wird die Aufnahme als *veraltet* markiert.
- **Aufnahmen aufbereiten:** Stille am Anfang und Ende wird abgeschnitten, die Lautstärke angeglichen und eine Fassung in Telefonqualität erzeugt (8 kHz).
- **KI-Begrüßung:** Der eigene Stimmdienst (`stimme/`, Chatterbox, Open Source, MIT-Lizenz) lernt die Stimme aus den Aufnahmen des Mitarbeiters. Damit spricht er „Guten Tag, Frau Dr. Schneider!“. Jedes Ergebnis hört Whisper gegen; bei Aussetzern wird neu erzeugt. Anrufernamen laufen durch das Aussprache-Wörterbuch.
- **Nie warten lassen:** Ist die KI-Begrüßung nicht innerhalb von 2,5 Sekunden fertig, kommt die Aufnahme „Guten Tag!“. Die Begrüßung mit Namen liegt dann im Cache und ist beim nächsten Anruf sofort da.
- **Fehlende Aufnahmen** spricht vorübergehend die KI. Ohne Aufnahmen und ohne KI landet der Anrufer direkt in der sipgate-Mailbox.
- **Zeitangaben** („Das gilt bis einschließlich Freitag, 4. Dezember.“) kann die KI optional ebenfalls ansagen. Das ist standardmäßig aus.

## Nur deutsche Anbieter

| Aufgabe | Lösung | Wo die Daten liegen |
|---|---|---|
| Telefonie | **sipgate.io** (sipgate GmbH, Düsseldorf), Push-API | sipgate, Deutschland |
| Ansage | eigene Aufnahmen | eigener Server |
| Name des Anrufers | eigener KI-Stimmdienst (Chatterbox + Whisper, Open Source) | eigener GPU-Server |
| Nachrichten aufnehmen | **sipgate-Mailbox** | sipgate, Deutschland |
| Server | dieser Dienst, Docker | deutsches Rechenzentrum, z. B. Hetzner oder IONOS (beide mit GPU-Servern) |

## Ablauf eines Anrufs

```
Anrufer ──► iPhone (nimmt nicht ab) ── **61*<sipgate-Nummer>*11*20# ──► sipgate
   sipgate ──► POST /sg/<geheim>/anruf ──► Server: Status, Anrufer (Qto), Bausteine → WAV
   ◄── <Gather><Play>ansage.wav</Play></Gather>
   ├─ Taste 1 ─► Aufnahme „Einen Moment bitte …“ ─► <Dial> Vertretung
   └─ keine Taste ─► <Dial><Voicemail/> ─► sipgate-Mailbox ─► Rückrufliste (App, Web, Teams/Slack, Qto)
```

Gemessen auf dem Testsystem: Anruf mit vorhandenen Aufnahmen < 0,01 s. Erkannter Anrufer beim ersten Mal 2,5 s (Rückfall auf „Guten Tag!“, weil der Testrechner keine GPU hat), danach < 0,01 s mit Namen.

## In Betrieb nehmen

**1. Server** in einem deutschen Rechenzentrum mit NVIDIA-GPU, öffentlich per HTTPS erreichbar (sipgate akzeptiert keine selbst signierten Zertifikate):

```bash
cd anrufbeantworter
PUBLIC_URL=https://ab.example.de ADMIN_TOKEN=<langes-zufälliges-passwort> docker compose up -d --build
```

Damit starten Anrufbeantworter und Stimmdienst. Der Stimmdienst ist nur intern erreichbar, die Modelle werden beim Bauen geladen.

**2. sipgate**
- Konto (laut sipgate: *starter* oder *business*), **sipgate.io** (kostenlos) und **Voicemail** buchen.
- Pro Mitarbeiter eine sipgate-Rufnummer, oder eine gemeinsame Nummer (Zuordnung dann über die umleitende Handynummer, `diversion`).
- *Webhooks › URLs › Eingehende Anrufe*: die Adresse aus der Weboberfläche eintragen (*Telefonie & Qto*).
- Unter *Aufnahmen* die **Kurzansage** („Bitte sprechen Sie jetzt.“) herunterladen und in sipgate als Mailbox-Ansage hochladen.

**3. Weboberfläche** (`https://ab.example.de`, Anmeldung mit `ADMIN_TOKEN`)
- *Profil*: sipgate-Nummer und Diensthandy je Mitarbeiter, **App-Zugang erzeugen**.
- *Aufnahmen*: Stand je Mitarbeiter. Aufnehmen im Browser oder WAV hochladen, z. B. vom Profisprecher. *So klingt die KI in dieser Stimme*.
- *Telefonie & Qto*: Wartezeit, Zeitangaben, Firmen-Wörterbuch, Qto.

**4. iPhone** (*Einstellungen › Cloud-Anrufbeantworter*): verbinden, **Meine Aufnahmen** einsprechen (Text zum Ablesen, anhören, verwenden), Umleitungscode wählen, *Wie am Telefon anhören*. Zum Schluss einmal vom Festnetz anrufen und nicht annehmen.

## Sicherheit und Datenschutz

| Zugriff | Schutz |
|---|---|
| `/sg/<geheim>/*` (sipgate) | sipgate signiert Webhooks nicht. Deshalb enthält die Adresse einen zufälligen geheimen Teil, der sich in der Weboberfläche erneuern lässt. Nur HTTPS. |
| `/audio/<hash>.wav` | Nicht erratbare Dateinamen (HMAC). Dateien werden nach 24 Stunden gelöscht, weil persönliche Begrüßungen Kundennamen enthalten. |
| `/api/app/*` (iPhone) | Persönlicher Zugangsschlüssel. Der Server speichert nur den SHA-256-Hash, das iPhone legt ihn im Schlüsselbund ab. Jeder sieht und ändert nur die eigenen Aufnahmen. |
| `/api/*` (Verwaltung) | `ADMIN_TOKEN`; ohne ihn startet der Server nur auf localhost. |

**Stimmaufnahmen sind personenbezogene Daten.** Das Klonen der Stimme für die Namensbegrüßung braucht eine **schriftliche Einwilligung** des Mitarbeiters bzw. eine entsprechende Lizenz des Sprechers. Beim Ausscheiden werden Aufnahmen gelöscht. Weiter offen: Auftragsverarbeitungsverträge mit sipgate und dem Rechenzentrum, Löschfristen in der sipgate-Mailbox, Hinweis auf die Aufzeichnung, Datenbank statt JSON-Dateien.

## Entwickeln

```bash
cd anrufbeantworter
npm start      # http://127.0.0.1:8080 (ohne Stimmdienst: nur Aufnahmen bzw. Browser-Stimme im Simulator)
npm test       # 39 Tests: simulierte sipgate-Anrufe, Aufnahmen, Mixer mit Zeitlimit, Vertragstest mit der iPhone-App

# Optional: Stimmdienst lokal (CPU geht, ist aber langsam)
python3 -m venv .venv && .venv/bin/pip install torch==2.6.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cpu
.venv/bin/pip install chatterbox-tts==0.1.7 faster-whisper==1.2.1
PORT=5000 .venv/bin/python stimme/server.py
STIMME_URL=http://127.0.0.1:5000 STIMME_TIMEOUT_MS=300000 npm start
```

### Aufbau

```
src/
  core/engine.js        Status, Regeln, Ansage + Bausteinplan (Aufnahme oder KI je Satz)
  aufnahmen.js          Bausteinliste je Mitarbeiter, Aufnahmen aufbereiten, Referenzstimme
  tts/ansageAudio.js    Mixer: Aufnahmen + KI-Begrüßung → WAV 8 kHz, Zeitlimit mit Rückfall
  tts/stimmdienst.js    Anbindung an stimme/server.py
  telephony/sipgate.js  XML-Antworten für die sipgate.io-Push-API
  audio/wav.js          WAV lesen/schreiben, 8 kHz, Stille abschneiden, Lautstärke angleichen
  appsync.js, crm/, server.js
stimme/                 KI-Stimmdienst (Python): Chatterbox + Whisper-Gegenprüfung
public/                 Weboberfläche (Verwaltung, Aufnahmen im Browser)
```

### Schnittstellen

| Bereich | Endpunkte |
|---|---|
| sipgate.io | `POST /sg/<geheim>/anruf`, `/daten`, `/ende`; `GET /audio/<hash>.wav` |
| iPhone-App | `GET /api/app/ich`, `PUT /api/app/konfiguration`, `GET /api/app/vorschau[.wav]`, `GET /api/app/aufnahmen`, `PUT/DELETE /api/app/aufnahmen/:key`, `GET /api/app/aufnahmen/:key.wav`, `POST /api/app/stimmtest`, `GET/PATCH /api/app/nachrichten` |
| Verwaltung | wie App unter `/api/users/:id/aufnahmen…`, `/stimmtest`, `/mailbox-ansage.wav`; dazu `GET /api/config`, `PUT /api/users/:id`, `POST/DELETE /api/users/:id/app-zugang`, `PUT /api/telefonie`, `PUT /api/lexikon`, `PUT /api/crm`, `POST /api/vorschau[/audio]`, `GET/PATCH/DELETE /api/nachrichten` |

Testanrufer (fiktiv): `040 1234567` (Kundin, eigene Betreuung), `089 7654321` (VIP), `030 5550100` (Praxis ohne Ansprechpartner), `0221 998877` (Interessentin), `03641 000 300` (Kollegin, per Du).

### Qto/ZSWork anbinden

Unter *Telefonie & Qto* Basis-URL, Token und Pfade eintragen (`{nummer}` wird durch die E.164-Nummer ersetzt) und mit *Verbindung testen* prüfen. Endpunkte und Feldnamen sind noch **Annahmen**. Das Feld-Mapping steht in `src/crm/rest.js` (`mapContact`).
