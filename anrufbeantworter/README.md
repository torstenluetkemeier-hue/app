# zollsoft Anrufbeantworter

| Teil | Ordner | Zweck |
|---|---|---|
| **iPhone-App** | [`ios/`](ios/README.md) | Einheitliche Ansage mit angenehmer Stimme, Status/Urlaub/Vertretung, Aussprache-Prüfung mit freiwilliger Korrektur. Funktioniert allein über die Mailbox oder zusammen mit dem Cloud-Anrufbeantworter. |
| **Cloud-Anrufbeantworter** | `src/`, `public/` | Nimmt per Rufumleitung vom iPhone ab: Ansage wechselt automatisch, erkannte Anrufer werden mit Namen begrüßt (Qto/ZSWork), Tastenwahl zur Vertretung, Aufnahme, Rückrufliste. Ohne Firmen-Telefonanlage. |

Das Fachkonzept steht in **[KONZEPT.md](KONZEPT.md)**.

## So funktioniert der Cloud-Anrufbeantworter

```
Anrufer ──► iPhone (nimmt nicht ab)
              │  bedingte Rufumleitung  **61*<Cloud-Nummer>*11*20#
              ▼
          Twilio-Nummer ──► POST /tw/voice ──► dieser Server
              ▲                                   │ Status/Kalender aus der iPhone-App
              │  TwiML: Ansage (neurale Stimme,  │ Anrufer in Qto/ZSWork nachschlagen
              │  mit Aussprache-Korrekturen),     │ Aussprache-Wörterbuch → SSML
              │  Taste 1 → Vertretung, Aufnahme   ▼
              └────────────────────────────── Nachricht → App, Teams/Slack, Qto-Aufgabe
```

Die iPhone-App überträgt Status, Kalender, Vertretungen, Texte und Wörterbuch automatisch an den Server. Damit muss nie wieder eine Ansage neu aufgesprochen werden.

## In Betrieb nehmen

**1. Server bereitstellen** (öffentlich per HTTPS erreichbar, am besten in der EU)

```bash
docker build -t anrufbeantworter anrufbeantworter/
docker run -d -p 8080:8080 -v ab-daten:/data \
  -e PUBLIC_URL=https://ab.example.de \
  -e ADMIN_TOKEN=<langes-zufälliges-passwort> \
  -e TWILIO_ACCOUNT_SID=AC… -e TWILIO_AUTH_TOKEN=… \
  anrufbeantworter
```

Davor gehört ein Reverse-Proxy mit TLS (z. B. Caddy oder Traefik). Ohne `ADMIN_TOKEN` startet der Server nur auf localhost.

**2. Twilio einrichten**
- Twilio-Konto anlegen (für Datenhaltung in der EU die Region *IE1* wählen).
- Deutsche Rufnummer(n) kaufen. Twilio verlangt dafür ein *Regulatory Bundle* mit Firmenadresse in Deutschland.
- An jeder Nummer eintragen: *A call comes in* → Webhook `POST https://ab.example.de/tw/voice`. *Call status changes* → `https://ab.example.de/tw/status`.
- Entweder bekommt jeder Mitarbeiter eine eigene Nummer, oder alle teilen eine Nummer. Im zweiten Fall ordnet der Server den Anruf über die umleitende Handynummer (`ForwardedFrom`) zu. Das liefern aber nicht alle Netze zuverlässig, deshalb sind eigene Nummern die sichere Wahl.

**3. Weboberfläche** (`https://ab.example.de`, mit `ADMIN_TOKEN` anmelden)
- *Telefonie & Qto*: Stimme wählen (Standard: Polly Vicki, neural), Firmen-Wörterbuch für Kundennamen, Qto-Anbindung.
- *Profil*: Cloud-Nummer und Diensthandy je Mitarbeiter eintragen, **App-Zugang erzeugen**.

**4. iPhone** (*Einstellungen › Cloud-Anrufbeantworter*)
- Server und Zugangsschlüssel eintragen, *Verbinden*.
- Den angezeigten Umleitungscode (`**61*…*11*20#`, `**67*…#`, `**62*…#`) kopieren und in der Telefon-App wählen.
- *Probeanruf* tippen: Die Ansage kommt mit der Cloud-Stimme aufs Handy.

**Optional:** `STT_URL` (+ `STT_API_KEY`, `STT_MODEL`) auf einen OpenAI-kompatiblen Transkriptionsdienst setzen, z. B. einen selbst gehosteten Whisper-Server. Dann kommen Nachrichten als Text. Die Transkription von Twilio selbst kann kein Deutsch.

## Sicherheit und Datenschutz

| Zugriff | Schutz |
|---|---|
| `/tw/*` (Twilio) | Jede Anfrage wird über `X-Twilio-Signature` (HMAC-SHA1 mit dem Auth-Token) geprüft. |
| `/api/app/*` (iPhone) | Persönlicher Zugangsschlüssel. Der Server speichert nur den SHA-256-Hash, das iPhone legt den Schlüssel im Schlüsselbund ab. Jeder sieht nur die eigenen Nachrichten. |
| `/api/*` (Verwaltung) | `ADMIN_TOKEN` |
| Aufnahmen | Bleiben bei Twilio und werden über den Server ausgeliefert. Twilio-Zugangsdaten verlassen den Server nie. |

Offen für den Produktivbetrieb: Löschfristen für Aufnahmen, Hinweis auf die Aufzeichnung in der Ansage, Auftragsverarbeitungsvertrag mit Twilio, Datenbank statt JSON-Dateien. Siehe [KONZEPT.md](KONZEPT.md).

## Entwickeln

```bash
cd anrufbeantworter
npm start      # http://127.0.0.1:8080 (ohne Twilio: Simulator in der Weboberfläche)
npm test       # 32 Tests, darunter simulierte, signierte Twilio-Anrufe und ein Vertragstest mit der iPhone-App
```

Testanrufer (fiktiv): `040 1234567` (Kundin, eigene Betreuung), `089 7654321` (VIP), `030 5550100` (Praxis ohne Ansprechpartner), `0221 998877` (Interessentin), `03641 000 300` (Kollegin, per Du).

### Aufbau

```
src/
  core/              Reine Logik: Status, Regeln, Ansage, Aussprache → SSML
  telephony/twilio.js  TwiML, Signaturprüfung, Probeanruf, Aufnahmen
  appsync.js         Übernahme der Einstellungen aus der iPhone-App
  crm/               Qto/ZSWork-Adapter (REST, Zeitlimit, Cache) + Testdaten
  stt.js             optionale Transkription
  server.js          Routing, Zugriffsschutz
public/              Weboberfläche (Verwaltung)
test/                node:test (fixtures/app-payload.json wird vom Swift-Test erzeugt)
```

### Schnittstellen

| Bereich | Endpunkte |
|---|---|
| Twilio | `POST /tw/voice`, `/tw/taste`, `/tw/aufnahme-ende`, `/tw/aufnahme`, `/tw/status` |
| iPhone-App | `GET /api/app/ich`, `PUT /api/app/konfiguration`, `GET /api/app/vorschau`, `POST /api/app/probeanruf`, `GET/PATCH /api/app/nachrichten[/:id]`, `GET /api/app/nachrichten/:id/audio` |
| Verwaltung | `GET /api/config`, `PUT /api/users/:id`, `POST/DELETE /api/users/:id/app-zugang`, `PUT /api/telefonie`, `PUT /api/lexikon`, `PUT /api/crm`, `POST /api/vorschau`, `GET/PATCH/DELETE /api/nachrichten` |
| Eigenes Voice-Gateway statt Twilio | `POST /api/telephony/incoming`, `/dtmf`, `/recording` (liefert auch SSML) |

Ein anderer Telefonie-Anbieter (z. B. sipgate.io oder Vonage) lässt sich als weiteres Modul neben `telephony/twilio.js` ergänzen. Die Ansage-Logik bleibt gleich.

### Qto/ZSWork anbinden

Unter *Telefonie & Qto* Basis-URL, Token und Pfade eintragen (`{nummer}` wird durch die E.164-Nummer ersetzt) und mit *Verbindung testen* prüfen. Endpunkte und Feldnamen sind noch **Annahmen**. Das Feld-Mapping steht in `src/crm/rest.js` (`mapContact`).
