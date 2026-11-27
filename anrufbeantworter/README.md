# zollsoft Anrufbeantworter

Dieser Ordner enthält zwei Teile:

| Teil | Ordner | Zweck |
|---|---|---|
| **iPhone-App** *(Hauptprodukt)* | [`ios/`](ios/README.md) | Einheitliche Ansage mit angenehmer Stimme, Status/Urlaub/Vertretung, **Aussprache-Prüfung mit freiwilliger Korrektur**, Export für die Mailbox. Läuft nur auf dem iPhone, ohne Server und ohne Firmen-Telefonanlage. |
| Server-Prototyp *(optionale Ausbaustufe)* | `src/`, `public/` | Cloud-Anrufbeantworter per Rufumleitung: automatischer Statuswechsel, Begrüßung erkannter Anrufer mit Namen über **Qto**/**ZSWork**, Rückruf-Aufgaben. |

Das Fachkonzept steht in **[KONZEPT.md](KONZEPT.md)**.

---

# Server-Prototyp (optionale Ausbaustufe)

Ein Anrufbeantworter-Dienst, der Anrufer über **Qto** (künftig **ZSWork**) erkennt, sie mit Namen begrüßt, Grund und Dauer der Abwesenheit samt Vertretung nennt und Rückrufe als Aufgabe anlegt.

## Starten

Voraussetzung: Node.js ≥ 22. Externe Pakete werden nicht benötigt.

```bash
cd anrufbeantworter
npm start            # http://127.0.0.1:8080
npm test             # 21 automatisierte Tests
```

Umgebungsvariablen: `PORT`, `HOST` (Standard `127.0.0.1`), `DATA_DIR` (Ablage für `config.json` und `nachrichten.json`), `QTO_API_TOKEN`, `ZSWORK_API_TOKEN`.

> Der Prototyp hat noch **keine Anmeldung**. Deshalb lauscht er standardmäßig nur auf localhost.

## Ausprobieren

1. **Status**: z. B. „Im Termin → Online-Präsentation bis 15:00“ setzen und anhören.
2. **Kalender**: Urlaub mit Vertretung eintragen.
3. **Simulator**: Testanrufer wählen (z. B. *Herr Prof. Dr. Hoffmann*, VIP), Anruf starten, Ansage anhören, Taste 1 drücken oder eine Nachricht hinterlassen.
4. **Nachrichten**: Nachricht mit erkanntem Anrufer und angelegter Rückruf-Aufgabe ansehen.

Testanrufer (fiktiv): `040 1234567` (Kundin, eigene Betreuung), `089 7654321` (VIP), `030 5550100` (Praxis ohne Ansprechpartner), `0221 998877` (Interessentin), `03641 000 300` (Kollegin, per Du).

## Projektstruktur

```
src/
  core/            Reine Logik ohne I/O (auch in einer Mobil-App wiederverwendbar)
    engine.js      Status ermitteln, Regeln anwenden, Ansage zusammensetzen
    defaults.js    Modi, Termin-Arten, Standardtexte, Standardkonfiguration
    template.js    Platzhalter {{x}}, {{#x}}…{{/x}}, {{^x}}…{{/x}}
    time.js        Europe/Berlin, gesprochene Datums-/Uhrzeitangaben
    phone.js       E.164-Normalisierung, Nummern für die Sprachausgabe
  crm/             Qto/ZSWork-Adapter (REST, Zeitlimit, Cache) + Testdaten
  server.js        HTTP-API + statische Weboberfläche
  store.js         JSON-Dateiablage (Prototyp)
  notify.js        Benachrichtigung (Webhook, E-Mail simuliert)
public/            Weboberfläche (ohne Framework)
test/              node:test
```

## Telefonie-API (für das Voice-Gateway)

| Aufruf | Zweck |
|---|---|
| `POST /api/telephony/incoming` `{ from, to \| userId, callId? }` | Liefert `callId` und den **Ablauf**: `ansage` (Text für TTS) → optional `auswahl` (Taste, Ziel) → optional `aufnahme` (max. Sekunden) → `auflegen`, oder direkt `weiterleiten`. |
| `POST /api/telephony/dtmf` `{ callId, taste }` | Bei passender Taste: `{ aktion: "weiterleiten", ziel, ansage }`. |
| `POST /api/telephony/recording` `{ callId, transkript, dauerSekunden, aufnahmeUrl }` | Speichert die Nachricht, legt die Rückruf-Aufgabe in Qto/ZSWork an und benachrichtigt. |

Beispiel:

```bash
curl -s localhost:8080/api/telephony/incoming -H 'Content-Type: application/json' \
  -d '{"from":"040 1234567","to":"+49 3641 000 100"}'
```

Weitere Endpunkte: `GET /api/config`, `PUT /api/users/:id`, `PUT /api/users/:id/status`, `POST|DELETE /api/users/:id/kalender`, `POST /api/vorschau`, `PUT /api/crm`, `POST /api/crm/test`, `GET|PATCH|DELETE /api/nachrichten`.

## Qto/ZSWork anbinden

Unter **Qto / ZSWork** in der Oberfläche die Basis-URL, das Token und die Pfade eintragen (`{nummer}` wird durch die E.164-Nummer ersetzt) und mit „Verbindung testen“ prüfen. Endpunkte und Feldnamen sind im Prototyp **Annahmen**. Das Feld-Mapping steht in `src/crm/rest.js` (`mapContact`).
