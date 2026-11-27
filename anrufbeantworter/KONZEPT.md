# Konzept: Intelligenter Anrufbeantworter für zollsoft

Stand: 27.11.2026 · Status: Vorschlag + Prototyp (v0.5)

## 0. Aktuelle Ausrichtung (v0.2): iPhone-App ohne Telefonanlage

Nach Abstimmung liegt der Schwerpunkt auf einer **reinen iPhone-App**, ohne Anbindung an die Firmen-Telefonanlage. Im Mittelpunkt stehen **die Ansage selbst**, **eine angenehme, einheitliche Stimme** und **die korrekte Aussprache auch schwieriger Namen** (Testroutinen, Abfragen, freiwillige Korrekturen in Lautschrift oder IPA). Umsetzung: [`ios/`](ios/README.md).

**Technische Grenze:** iOS erlaubt keiner App, Anrufe selbst anzunehmen. Daraus folgt:

| Ziel | Mit reiner iPhone-App | Mit optionaler Cloud-Ausbaustufe (Rufumleitung) |
|---|---|---|
| Einheitliche Ansage, angenehme Stimme, korrekte Aussprache | ✅ | ✅ echte Aufnahmen, KI nur für den Anrufernamen |
| Status, Urlaub, Termine, Vertretung | ✅ Ansage wird erzeugt, Wechsel per Erinnerung und einmaligem Einspielen in die Mailbox | ✅ wechselt automatisch |
| Anrufer mit Namen begrüßen (Qto/ZSWork) | ❌ die Mailbox spielt für alle dieselbe Ansage | ✅ |
| Rückruf-Aufgabe, Transkript | ❌ (Mailbox des Netzbetreibers) | ✅ Rückrufliste + Qto-Aufgabe; Aufnahme in der sipgate-Mailbox |

**Stand v0.5 – nur deutsche Anbieter, echte Stimme:** Das iPhone leitet per **bedingter Rufumleitung** (`**61*…*11*20#`, `**67*…#`, `**62*…#`) auf eine **sipgate**-Nummer um (sipgate GmbH, Düsseldorf, Push-API „sipgate.io“). Die Ansage besteht aus **echten Aufnahmen**, die jeder Mitarbeiter in der iPhone-App einspricht oder ein Profisprecher aufnimmt. Nur der **Name eines erkannten Anrufers** wird von einem eigenen KI-Stimmdienst (Chatterbox, Open Source) **in derselben Stimme** ergänzt. Der Stimmdienst läuft auf einem eigenen GPU-Server in Deutschland; ist er zu langsam, kommt die Aufnahme „Guten Tag!“. Die Sprachnachricht nimmt die **sipgate-Mailbox** auf. Einrichtung: [README.md](README.md).

Verworfen: rein synthetische Ansagen (Piper) klangen zu unnatürlich. Als Alternative zur eigenen KI kommt **stimme.ai** (BrennerMedien GmbH, Augsburg; Profisprecher-Stimme, eigene Server in Augsburg, Preise auf Anfrage, Early Access) infrage.

Geprüfte Alternativen: **Placetel** (Köln) eignet sich nicht, weil die Call-Control-API keine eigenen Audiodateien und keine Tasteneingabe kennt. Die US-Dienste (Twilio, Cloud-Sprachdienste von Amazon/Google/Microsoft) sind bewusst ausgeschlossen. Wer auch Aufnahme und Transkription selbst betreiben will, nimmt einen eigenen Asterisk an einem deutschen SIP-Trunk.

**Zum Vergleich mit HiProCall:** HiProCall arbeitet mit dem Netzbetreiber zusammen und lädt fertige Ansagen direkt in dessen Mailbox. Das ist bequem, bleibt aber eine feste Ansage für alle Anrufer. Unser Weg über die Rufumleitung braucht keine Partnerschaft mit einem Netzbetreiber und erzeugt die Ansage bei jedem Anruf neu. Nur so sind Begrüßung mit Namen, automatischer Statuswechsel und Tastenwahl zur Vertretung möglich.

Die Abschnitte ab 1 beschreiben die ursprüngliche Variante mit Firmen-Telefonanlage. Architektur, Datenschutz und Qto-Anbindung gelten unverändert auch für die Cloud-Variante.

## 1. Ziel

Jede Mitarbeiterin und jeder Mitarbeiter bei zollsoft bekommt einen persönlichen, stark konfigurierbaren Anrufbeantworter, der

1. **den Anrufer erkennt**: Die Rufnummer wird in **Qto** (künftig **ZSWork**) nachgeschlagen. Kunden (Praxen), Interessenten und Kollegen werden **mit Namen begrüßt**.
2. **klar sagt, wer angerufen wurde**: Name, Funktion, „zollsoft, Ihr Team für tomedo“.
3. **sagt, warum niemand abnimmt und wann es weitergeht**: im Termin (Online-Präsentation, Präsentation vor Ort, Schulung, Installation …), unterwegs, Urlaub, krank, außerhalb der Geschäftszeiten. Dazu kommt die **Vertretung mit Rufnummer**.
4. **den Rückruf organisiert**: Die Nachricht wird aufgenommen und transkribiert, als Rückruf-Aufgabe in Qto/ZSWork angelegt, und der Mitarbeiter wird benachrichtigt.

## 2. Vorbild HiProCall: was wir übernehmen und was wir besser machen

HiProCall (Business/Enterprise Voicemail) bietet laut Hersteller:

| HiProCall | Übernahme bei uns |
|---|---|
| Ansagetypen **Standard**, **Beschäftigt** (kurzfristig, z. B. Meeting, mit Grund und Vertreter), **Abwesend** (längerfristig, mit Dauer, Grund und Vertreter) | ✅ als Modi *Standard*, *Im Termin*, *Unterwegs*, *Urlaub*, *Krank*, *Feierabend* |
| Programmierbare **Kalenderfunktion**: Ansage für den Urlaub vorplanen, danach automatische Rückkehr zur Standardansage | ✅ Kalendereinträge + „bis“-Zeit beim manuellen Status, automatische Rückkehr |
| Name und Firmenname in der Ansage, **Textvorlagen** oder eigener Text | ✅ Vorlagen mit Platzhaltern pro Baustein |
| Auswahl von **Stimmen** (inkl. KI-Stimmen), Hintergrundmusik, Sound-Branding | ⏳ Phase 2: TTS-Stimme wählbar, optional zollsoft-Jingle |
| Verwaltung per PC, Tablet und Smartphone | ✅ Weboberfläche (responsiv); Mobil-App optional in Phase 3 |
| Admin-Funktionen, Unternehmensstruktur, Abwesenheitsmanager | ⏳ Phase 2/3: Team-Ansichten, zentrale Vorlagen |

**Was HiProCall nicht kann und uns unterscheidet:** HiProCall erzeugt *statische* Ansagen und lädt sie in die Mailbox. Wir erzeugen die Ansage **bei jedem Anruf neu**. Nur so sind möglich:

- persönliche Begrüßung des erkannten Anrufers aus Qto/ZSWork („Guten Tag, Frau Dr. Schneider!“),
- **Regeln je Anrufer** (VIP-Kunde → Weiterleitung zur Vertretung per Taste 1, eigene Kunden → hohe Priorität, Werbenummern sperren),
- „Ich bin **am Montag ab 8 Uhr** wieder da“ aus den Geschäftszeiten berechnet,
- Rückruf-Aufgabe direkt im Kundenkontext (Kundennummer, offene Tickets).

## 3. Die zentrale Architekturentscheidung: Wo läuft der Anrufbeantworter?

| Variante | Bewertung |
|---|---|
| **A: Zentraler Dienst an der Telefonanlage** *(empfohlen)*. Bei „keine Annahme / besetzt / Status abwesend“ leitet die TK-Anlage auf den Anrufbeantworter-Dienst (SIP) um. | ✅ Dynamische, personalisierte Ansagen, CRM-Zugriff serverseitig, ein Dienst für alle, Zugangsdaten bleiben im Rechenzentrum. Voraussetzung: Die TK-Anlage kann per SIP oder Cloud-API umleiten. |
| **B: App auf dem Smartphone nimmt selbst ab** | ❌ iOS erlaubt Apps nicht, Anrufe automatisch anzunehmen. Android geht nur eingeschränkt (Call-Screening-Rolle, kein vollwertiges Abheben mit Ansage). Nicht tragfähig. |
| **C: Mobilfunk-Umleitung auf den zentralen Dienst** | ✅ Ergänzt Variante A für Diensthandys: bedingte Rufumleitung bei Nichtannahme (GSM-Code `**61*<Dienstnummer>#`) auf eine Einwahlnummer des Dienstes. Die Rufnummer des Anrufers wird in der Regel mitgeschickt, der Umleitungs-Header nennt den Mitarbeiter. |

**Die „App“ ist deshalb die Konfigurations- und Nachrichtenoberfläche** (Web, später auch mobil oder in ZSWork eingebettet). Die Telefonie macht der zentrale Dienst. So funktioniert das System gleich für Festnetz, Softphone und Diensthandy.

## 4. Architektur

```
 Anrufer ──► TK-Anlage / Mobilfunk-Umleitung
                 │  (SIP, keine Annahme nach n Sekunden / besetzt / Status)
                 ▼
         Voice-Gateway (z. B. Asterisk/FreeSWITCH, jambonz oder Cloud-API der TK-Anlage)
                 │  HTTP: /api/telephony/incoming · /dtmf · /recording
                 ▼
 ┌──────────────── Anrufbeantworter-Dienst ──────────────────┐
 │  Regel-Engine (Status ▸ Kalender ▸ Geschäftszeiten ▸ Regeln)│
 │  Ansage-Baukasten (Vorlagen + Platzhalter)                  │
 │  CRM-Adapter ── Qto  │  ZSWork  │  Testdaten                 │──► Qto / ZSWork (Kontakt suchen, Aufgabe anlegen)
 │  Nachrichten, Benachrichtigung                              │──► E-Mail, Teams/Slack/Mattermost, Push
 └──────────────────────────────────────────────────────────────┘
        ▲                       │
        │ Konfiguration         ▼ Sprache
   Web-/Mobil-Oberfläche     TTS (Ansage) · STT (Transkript), DSGVO-konform gehostet
```

**Latenz:** Die CRM-Suche startet schon beim **Klingeln** (Prefetch) und hat ein hartes Zeitlimit (Standard 1,5 s) mit Cache. Antwortet Qto/ZSWork nicht, wird neutral begrüßt. Der Anruf wartet nie auf das CRM.

## 5. Ablauf eines Anrufs

1. Anruf auf Max Meyer, keine Annahme → TK-Anlage leitet um, Voice-Gateway ruft `POST /api/telephony/incoming {from, to}`.
2. Dienst normalisiert die Nummer (E.164) und sucht in Qto/ZSWork: *Frau Dr. Schneider, Hausarztpraxis am Markt, Kundin von Max*.
3. Status ermitteln: manueller Status (mit Ablaufzeit) > Kalendereintrag > Geschäftszeiten > Standard.
4. Regeln anwenden (z. B. „Meine Kunden → hohe Priorität, Support-Hinweis“).
5. Ansage zusammensetzen und als Sprache ausgeben:
   > „Guten Morgen, Frau Dr. Schneider! Sie sind verbunden mit dem Anschluss von Max Meyer, Kundenberater bei zollsoft, Ihrem Team für tomedo. Ich bin gerade in einer Online-Präsentation, voraussichtlich bis 11 Uhr 30, und daher nicht erreichbar. … Ihre Rufnummer liegt mir bereits vor.“
6. Optional Taste 1 → Weiterleitung zur Vertretung.
7. Aufnahme → `POST /api/telephony/recording` → Transkript, Rückruf-Aufgabe in Qto/ZSWork, Benachrichtigung.

## 6. Was konfigurierbar ist

| Bereich | Einstellungen |
|---|---|
| **Profil** | Vorname, Nachname, Funktion, Team, Durchwahl, E-Mail; Firma/Produkt (zollsoft/tomedo), Support-Nummer |
| **Status (sofort)** | Automatisch · Nicht erreichbar · Im Termin (Online-Präsentation, Präsentation vor Ort, Schulung, Webinar, Kundentermin, Installation, Besprechung, anderes Gespräch, Freitext) · Unterwegs (Dienstreise, Messe, Fortbildung, Freitext) · Urlaub · Krank; jeweils mit „bis“ und Vertretung |
| **Kalender** | Geplante Termine/Abwesenheiten (ganztägig oder mit Uhrzeit), eigene Vertretung je Eintrag; der kürzere Eintrag gewinnt bei Überschneidung |
| **Geschäftszeiten** | Pro Wochentag mehrere Zeitfenster; daraus „Ich bin am Montag ab 8 Uhr wieder da“ |
| **Vertretungen** | Beliebig viele, eine Standard-Vertretung, die je Modus automatisch genannt wird |
| **Ansagen** | 14 Textbausteine mit Platzhaltern und bedingten Abschnitten, Zurücksetzen auf Standard, Vorschau je Anrufer und Status |
| **Anrufer-Regeln** | Bedingungen: alle, Kunden, meine Kunden, VIP, Kollegen, unbekannt, unterdrückt, bestimmte Nummern; jeweils auf Modi einschränkbar. Aktionen: Weiterleitung anbieten, sofort weiterleiten, Priorität, Support-Hinweis, Zusatztext, Namen nicht nennen, sperren |
| **Verhalten** | Anruferkennung an/aus, Name nennen (immer / nur Kunden & Kollegen / nie), Aufnahme, max. Länge, Transkription, Rückruf-Aufgabe, Weiterleitungstaste, Benachrichtigung (E-Mail, Webhook) |
| **Integration** | Datenquelle Qto / ZSWork / Testdaten, URL, Token, Pfade, Zeitlimit, Cache |

## 7. Anbindung Qto und ZSWork

Der Prototyp kapselt das CRM hinter einer schmalen Schnittstelle (`src/crm/`):

```js
findByPhone(e164)        → Kontakt | null
createCallbackTask(task) → { id, url }
healthCheck()            → { ok, info }
```

Der Wechsel von Qto zu ZSWork ist **eine Einstellung**. Regeln, Ansagen und Oberfläche bleiben gleich.

**Was wir von den Qto/ZSWork-Teams brauchen:**

1. Endpunkt **Rufnummernsuche** über *normalisierte* Nummern (E.164), am besten mit Index, Antwort < 300 ms.
2. Kontaktfelder: Anrede, Titel, Vor-/Nachname, Organisation (Praxis), Kundennummer, Typ (Kunde/Interessent/Partner/intern), Betreuer, VIP-Kennzeichen, offene Tickets.
3. Endpunkt **Aufgabe/Rückruf anlegen** (zuständiger Mitarbeiter, Priorität, Verknüpfung zum Kontakt, Link auf die Aufnahme).
4. **Service-Zugang** (technischer Benutzer, Token, nur Lese- und Aufgabenrechte).
5. *ZSWork:* Mitarbeiter-Abwesenheiten/Kalender als Quelle für den automatischen Status. Dann muss niemand Urlaub doppelt pflegen.

## 8. Datenschutz und Sicherheit

- **Name nur bei eindeutiger Zuordnung:** Gehört eine Nummer zu mehreren Personen (Praxis-Zentrale), wird nur die Praxis begrüßt („liebes Team von …“). Ist im Prototyp umgesetzt.
- Namensnennung pro Mitarbeiter abschaltbar (immer / nur Kunden / nie) und pro Regel unterdrückbar.
- **Nachrichten können Gesundheitsdaten enthalten** (Anrufe aus Praxen). Deshalb: Zugriff nur für den Empfänger und seine Vertretung, Verschlüsselung at rest, Löschfrist für Aufnahmen (Vorschlag 30 Tage), Hinweis auf Aufzeichnung in der Ansage.
- **TTS/STT in der EU oder selbst gehostet** (z. B. Whisper und Piper on-prem), sonst AV-Vertrag.
- Anmeldung per SSO (Entra ID/Google), Rollen: Mitarbeiter, Teamleitung, Admin. API-Tokens nur per Umgebungsvariable/Secret-Store.
- Audit-Log für Konfigurationsänderungen.

## 9. Was der Prototyp heute kann

- Vollständige Regel- und Ansage-Engine (getestet, 21 automatisierte Tests)
- Weboberfläche: Status, Kalender, Ansagen-Editor mit Vorschau, Anrufer-Regeln, Profil/Geschäftszeiten/Vertretungen, Qto/ZSWork-Einstellungen mit Verbindungstest, **Anruf-Simulator mit Sprachausgabe** (Browser-TTS) und Diktat, Nachrichten-Eingang
- Telefonie-API für ein Voice-Gateway (incoming / dtmf / recording)
- CRM-Adapter: Testdaten sowie ein generischer REST-Adapter für Qto/ZSWork mit Zeitlimit, Cache und Feld-Mapping
- Mehrere Mitarbeiter, Benachrichtigung per Webhook (Teams/Slack/Mattermost), E-Mail simuliert

**Bewusst noch nicht enthalten:** echte Telefonie/SIP, Server-TTS/STT, Login/SSO, Datenbank (JSON-Datei), echte Qto-Endpunkte (Pfade und Felder sind Annahmen), Feiertage, Outlook-Sync.

## 10. Roadmap

| Phase | Inhalt | Ergebnis |
|---|---|---|
| **0: Prototyp** *(dieser Stand)* | Engine, Oberfläche, Simulator, Adapter-Gerüst | Fachliche Abstimmung, Demo |
| **1: Pilot** (≈ 4–6 Wochen) | Anbindung der TK-Anlage über ein Voice-Gateway, Server-TTS, Qto nur lesend, SSO, Datenbank, 5–10 Pilotnutzer aus Vertrieb und Schulung | Echte Anrufe mit Namensbegrüßung |
| **2: Ausbau** | Aufnahme und Transkription, Rückruf-Aufgaben in Qto, Kalender-Sync (Outlook/Exchange), Feiertage, Stimmenauswahl, Mehrsprachigkeit (DE/EN), Löschfristen | Produktivbetrieb für alle |
| **3: ZSWork** | Umschalten auf den ZSWork-Adapter, Abwesenheiten aus ZSWork, Einbettung der Oberfläche in ZSWork, Team-/Hotline-Ansagen, Auswertungen (verpasste Anrufe, Rückrufquote) | Ein System statt zwei |

## 11. Offene Fragen

1. Welche **TK-Anlage** setzt zollsoft ein, und unterstützt sie SIP-Umleitung bzw. eine Call-Control-API? Davon hängt das Voice-Gateway ab.
2. Laufen **Diensthandys** über die Anlage (FMC), oder brauchen wir Variante C (Mobilfunk-Umleitung)?
3. Welche **Qto-API** gibt es heute für Kontakte und Aufgaben, und wer ist Ansprechpartner? Wann sind die ZSWork-Endpunkte geplant?
4. **Stimme:** synthetische Stimme für alle, oder die Begrüßung mit eigener Stimme aufnehmen und nur die dynamischen Teile per TTS erzeugen?
5. Sollen **Kollegen geduzt** werden (heute als Option je Kontakt)?
6. Wer darf Regeln wie „sofort durchstellen“ setzen: jeder selbst oder nur die Teamleitung?
