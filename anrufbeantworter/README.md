# zollsoft Anrufbeantworter

| Teil | Ordner | Zweck |
|---|---|---|
| **iPhone-App** | [`ios/`](ios/README.md) | Einheitliche Ansage mit angenehmer Stimme, Status/Urlaub/Vertretung, Aussprache-Prüfung mit freiwilliger Korrektur. Funktioniert allein über die Mailbox oder zusammen mit dem Cloud-Anrufbeantworter. |
| **Cloud-Anrufbeantworter** | `src/`, `public/`, `piper/` | Nimmt per Rufumleitung vom iPhone ab: Ansage wechselt automatisch, erkannte Anrufer werden mit Namen begrüßt (Qto/ZSWork), Taste 1 verbindet zur Vertretung, Rückrufliste. |

Das Fachkonzept steht in **[KONZEPT.md](KONZEPT.md)**.

## Nur deutsche Anbieter

| Aufgabe | Lösung | Wo die Daten liegen |
|---|---|---|
| Telefonie | **sipgate.io** (sipgate GmbH, Düsseldorf), Push-API | sipgate, Deutschland |
| Sprachausgabe | **Piper** (Open Source), läuft als Container auf dem eigenen Server | eigener Server |
| Nachrichten aufnehmen | **sipgate-Mailbox** (Funktion in sipgate buchen) | sipgate, Deutschland |
| Server | dieser Dienst, Docker | deutsches Rechenzentrum, z. B. Hetzner oder IONOS |

Ansagen, Kundennamen und Status verlassen die eigene Infrastruktur nur in Richtung sipgate. Einen Cloud-Sprachdienst aus den USA gibt es nicht.

## So funktioniert es

```
Anrufer ──► iPhone (nimmt nicht ab)
              │  bedingte Rufumleitung  **61*<sipgate-Nummer>*11*20#
              ▼
          sipgate-Nummer ──► POST /sg/<geheim>/anruf ──► dieser Server
              ▲                                            │ Status/Kalender aus der iPhone-App
              │                                            │ Anrufer in Qto/ZSWork nachschlagen
              │  <Gather><Play>ansage.wav</Play></Gather>  │ Text → Piper → WAV 8 kHz (Cache je Satz)
              │                                            ▼
              ├─ Taste 1 ─► „Einen Moment bitte …“ ─► <Dial> Vertretung
              └─ keine Taste ─► <Dial><Voicemail/> ─► sipgate-Mailbox nimmt die Nachricht auf
                                                   ─► Rückrufliste (App, Weboberfläche, Teams/Slack, Qto-Aufgabe)
```

- **Schnell:** Jeder Satz wird einzeln gesprochen und zwischengespeichert. Neu erzeugt wird nur der kurze Begrüßungssatz mit dem Namen des Anrufers. Alle übrigen Sätze erzeugt der Server vorab, sobald sich Status oder Texte ändern. Gemessen auf dem Testsystem: unbekannter Anrufer < 0,01 s, bekannter Anrufer 0,7–1,0 s.
- **Ausfallsicher:** Ist die Sprachausgabe nicht erreichbar, landet der Anrufer direkt in der sipgate-Mailbox.
- **Aussprache:** Firmen-Wörterbuch (z. B. Kundennamen) plus persönliches Wörterbuch aus der iPhone-App. Lautschrift wird eingesetzt, IPA geht als Piper-Rohphoneme (`[[ … ]]`) direkt an die Stimme.

## In Betrieb nehmen

**1. Server** in einem deutschen Rechenzentrum, öffentlich per HTTPS erreichbar (z. B. Caddy davor, sipgate akzeptiert keine selbst signierten Zertifikate):

```bash
cd anrufbeantworter
PUBLIC_URL=https://ab.example.de ADMIN_TOKEN=<langes-zufälliges-passwort> docker compose up -d --build
```

Damit starten der Anrufbeantworter und Piper mit den Stimmen Thorsten (Standard), Kerstin und Ramona. Piper ist nur intern erreichbar.

**2. sipgate**
- sipgate-Konto (laut sipgate: *starter* oder *business*), in der Feature-Übersicht **sipgate.io** buchen (kostenlos) und **Voicemail** buchen.
- Pro Mitarbeiter eine sipgate-Rufnummer, oder eine gemeinsame Nummer. Bei einer gemeinsamen Nummer erkennt der Server den Mitarbeiter an der umleitenden Handynummer (`diversion`).
- *Webhooks › URLs › Eingehende Anrufe*: die Adresse aus der Weboberfläche eintragen (*Telefonie & Qto*, enthält einen geheimen Teil).
- Mailbox-Ansage: In der Weboberfläche *Kurzansage herunterladen* („Bitte sprechen Sie jetzt.“) und in sipgate als Ansage der Mailbox hochladen. Sonst hören Anrufer nach unserer Ansage noch die Standardansage der Mailbox.
- Benachrichtigung über neue Sprachnachrichten (E-Mail/App) stellt man in sipgate ein.

**3. Weboberfläche** (`https://ab.example.de`, mit `ADMIN_TOKEN` anmelden)
- *Telefonie & Qto*: Stimme wählen und mit *Stimme testen* anhören, Firmen-Wörterbuch pflegen, Qto anbinden.
- *Profil*: sipgate-Nummer und Diensthandy je Mitarbeiter eintragen, **App-Zugang erzeugen**.

**4. iPhone** (*Einstellungen › Cloud-Anrufbeantworter*): Server und Zugangsschlüssel eintragen, Umleitungscode kopieren und in der Telefon-App wählen, *Wie am Telefon anhören*. Zum Schluss einmal vom Festnetz anrufen und nicht annehmen.

## Sicherheit und Datenschutz

| Zugriff | Schutz |
|---|---|
| `/sg/<geheim>/*` (sipgate) | sipgate signiert Webhooks nicht. Deshalb enthält die Adresse einen zufälligen geheimen Teil, der sich in der Weboberfläche erneuern lässt. Nur HTTPS. |
| `/audio/<hash>.wav` | Nicht erratbare Dateinamen (HMAC). Dateien werden nach 24 Stunden gelöscht, weil persönliche Begrüßungen Kundennamen enthalten. |
| `/api/app/*` (iPhone) | Persönlicher Zugangsschlüssel. Der Server speichert nur den SHA-256-Hash, das iPhone legt den Schlüssel im Schlüsselbund ab. |
| `/api/*` (Verwaltung) | `ADMIN_TOKEN`; ohne ihn startet der Server nur auf localhost. |

Offen für den Produktivbetrieb: Auftragsverarbeitungsvertrag mit sipgate und dem Rechenzentrum, Löschfristen in der sipgate-Mailbox, Hinweis auf die Aufzeichnung in der Ansage, Datenbank statt JSON-Dateien.

**Bekannte Grenze:** Die sipgate.io-Push-API kann selbst nicht aufnehmen. Die Sprachnachricht liegt deshalb in der sipgate-Mailbox (abhören per sipgate-App oder E-Mail). In der Rückrufliste dieses Dienstes steht, wer angerufen hat und dass eine Nachricht in der Mailbox sein kann. Wer Aufnahme und Transkription komplett selbst betreiben will: eigener Asterisk an einem deutschen SIP-Trunk (z. B. sipgate trunking) über die generische Schnittstelle `/api/telephony/*`.

## Entwickeln

```bash
cd anrufbeantworter
npm start      # http://127.0.0.1:8080 (ohne Piper: Simulator mit Browser-Stimme)
npm test       # 36 Tests, darunter simulierte sipgate-Anrufe und ein Vertragstest mit der iPhone-App

# Optional: Piper lokal für echte Sprachausgabe
python3 -m venv .venv && .venv/bin/pip install "piper-tts[http]==1.8.0"
.venv/bin/python -m piper.download_voices --data-dir voices de_DE-thorsten-high
.venv/bin/python -m piper.http_server --data-dir voices -m de_DE-thorsten-high --port 5000
PIPER_URL=http://127.0.0.1:5000 npm start
```

Testanrufer (fiktiv): `040 1234567` (Kundin, eigene Betreuung), `089 7654321` (VIP), `030 5550100` (Praxis ohne Ansprechpartner), `0221 998877` (Interessentin), `03641 000 300` (Kollegin, per Du).

### Aufbau

```
src/
  core/                 Reine Logik: Status, Regeln, Ansage, Aussprache
  telephony/sipgate.js  XML-Antworten für die sipgate.io-Push-API
  tts/piper.js          Anbindung Piper-HTTP-Server
  tts/ansageAudio.js    Ansage → WAV in Telefonqualität, Cache je Satz
  audio/wav.js          WAV lesen/schreiben, Umrechnung auf 8 kHz, Lautstärke angleichen
  appsync.js            Übernahme der Einstellungen aus der iPhone-App
  crm/                  Qto/ZSWork-Adapter (REST, Zeitlimit, Cache) + Testdaten
  server.js             Routing, Zugriffsschutz
public/                 Weboberfläche (Verwaltung)
piper/                  Container für die Sprachausgabe
test/                   node:test (fixtures/app-payload.json erzeugt der Swift-Test)
```

### Schnittstellen

| Bereich | Endpunkte |
|---|---|
| sipgate.io | `POST /sg/<geheim>/anruf` (newCall), `/daten` (Gather onData), `/ende` (onHangup); `GET /audio/<hash>.wav` |
| iPhone-App | `GET /api/app/ich`, `PUT /api/app/konfiguration`, `GET /api/app/vorschau`, `GET /api/app/vorschau.wav`, `GET/PATCH /api/app/nachrichten[/:id]` |
| Verwaltung | `GET /api/config`, `PUT /api/users/:id`, `POST/DELETE /api/users/:id/app-zugang`, `PUT /api/telefonie`, `POST /api/tts/test`, `GET /api/mailbox-ansage.wav`, `PUT /api/lexikon`, `PUT /api/crm`, `POST /api/vorschau[/audio]`, `GET/PATCH/DELETE /api/nachrichten` |
| Eigenes Voice-Gateway | `POST /api/telephony/incoming`, `/dtmf`, `/recording` |

### Qto/ZSWork anbinden

Unter *Telefonie & Qto* Basis-URL, Token und Pfade eintragen (`{nummer}` wird durch die E.164-Nummer ersetzt) und mit *Verbindung testen* prüfen. Endpunkte und Feldnamen sind noch **Annahmen**. Das Feld-Mapping steht in `src/crm/rest.js` (`mapContact`).
