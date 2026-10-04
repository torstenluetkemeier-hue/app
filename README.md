# Wochenleicht – nachhaltig abnehmen (iPhone & iPad)

Wochenleicht plant deine Mahlzeiten immer **eine ganze Woche im Voraus**, hält dabei deine **Kalorienobergrenze** ein, schreibt **Einkaufslisten pro Supermarkt in deiner Nähe**, merkt sich deinen **Vorrat inklusive Restmengen** nach jedem Einkauf, protokolliert dein **Wasser (mind. 3 Liter/Tag)** und **erinnert dich hartnäckig** daran, dranzubleiben. Ohne Registrierung per E-Mail und Passwort geht es nicht los. Die Zugangsdaten liegen auf deinem eigenen Server.

```
┌──────────────────────────┐        HTTPS/JSON         ┌──────────────────────────┐
│  iOS-App (SwiftUI)       │  ───────────────────────▶ │  server/ (Node.js)       │
│  ios/App                 │   Registrieren, Login,    │  Auth (scrypt + JWT)     │
│  ios/WochenleichtCore    │   Token, Datensync        │  SQLite, Docker + Caddy  │
└──────────────────────────┘                           └──────────────────────────┘
```

## Funktionen

| Anforderung | Umsetzung |
|---|---|
| Rezepte nach Kalorienobergrenze | 41 Rezepte (Frühstück, Mittag, Abend, Snack), die kcal werden aus 85 Zutaten berechnet. Tageslimit nach Mifflin-St Jeor minus Defizit (0,25 / 0,5 / 0,75 kg pro Woche), nie unter 1200 kcal (Frauen) bzw. 1500 kcal (Männer). Alternativ setzt du das Limit von Hand. Der Rezept-Browser filtert nach „max. kcal pro Portion“. |
| Wochenplanung | Rollierend: Heute plus 6 Tage sind immer geplant. Portionen werden in 0,25er-Schritten skaliert, damit der Tag unter dem Limit bleibt (≥ 85 % ausgenutzt). Der Planer vermeidet Wiederholungen und bevorzugt Zutaten, die schon im Vorrat sind (weniger Reste). Du kannst einzelne Mahlzeiten tauschen, Portionen anpassen, Tage neu planen und Rezepte ausschließen („mag ich nicht“). |
| Supermärkte in der Umgebung | Suche über Apple Karten (MapKit, 3 km Umkreis) nach Supermärkten und Discountern; Ketten wie Aldi, Lidl, Rewe oder Edeka werden erkannt. |
| Einkaufslisten pro Supermarkt | Eine Liste je Markt, sortiert nach Gängen. Du legst fest, was du wo kaufst: einen Standardmarkt, Kategorien („Gewürze bei Aldi“) oder einzelne Artikel per Kontextmenü. Mengen werden auf **handelsübliche Packungsgrößen** aufgerundet. Listen lassen sich teilen. |
| Vorrat merken | „Einkauf abschließen“ bucht die gekauften Packungen in den Vorrat. Jede gegessene Mahlzeit bucht die Zutaten wieder aus. Die Vorratsansicht zeigt den **Soll-Bestand** und **was nach den geplanten Gerichten übrig bleibt**, dazu Ablaufwarnungen für frische Ware und eine Inventurkorrektur. Gewürze und Öle kommen nur auf die Liste, wenn sie fehlen. |
| Wasser ≥ 3 l | Schnelleingabe (+250/+500/+750 ml oder eigene Menge), Fortschrittsring, „Plan bis jetzt“, Serie und 14-Tage-Diagramm. Das Ziel lässt sich nicht unter 3 l stellen. Direkt aus der Benachrichtigung heraus kannst du „+250 ml“ eintragen. |
| Penetrante Erinnerungen | Drei Stufen (Normal / Hartnäckig / **Penetrant**, voreingestellt): Wasser im Intervall, bei Rückstand doppelt so oft. Dazu jede Mahlzeit (mit „Gegessen ✓“-Aktion), eine Kochvorwarnung, Abend-Check, Wiegetag, Einkaufserinnerung, ein Hinweis, sobald du an einem deiner Supermärkte bist, und ein „Du bist vom Plan abgekommen“, wenn du die App tagelang nicht öffnest. Bei Rückstand erscheint außerdem ein roter Banner in der App. |
| Registrierung per E-Mail + Passwort | Pflicht beim ersten Start. Passwortregel: mind. 8 Zeichen mit Buchstabe und Ziffer. Refresh-Token im iOS-Schlüsselbund. Passwort ändern, abmelden und **Konto löschen** (App-Store-Pflicht) gehen in der App. |
| iPhone + iPad | Universelle App. Auf dem iPad erscheint der Wochenplan als Kartenraster. Daten werden über den Server zwischen den Geräten **synchronisiert**: Wasser-Einträge beider Geräte werden zusammengeführt, sonst gewinnt der neuere Stand. |

## Projektstruktur

```
server/                  Auth- & Sync-Server (Node.js ≥ 22.13, keine npm-Abhängigkeiten)
  src/app.js             Routen: /v1/auth/register|login|refresh|logout, /v1/me, /v1/me/password, /v1/data
  test/                  API-Tests (node:test)
  Dockerfile, docker-compose.yml, Caddyfile   Produktion mit automatischem HTTPS
ios/
  project.yml            XcodeGen-Projektdefinition
  App/                   SwiftUI-App (Views, Services, AppModel)
  WochenleichtCore/      Plattformunabhängige Logik als Swift Package + Unit-Tests
    Resources/recipes.json, ingredients.json   Rezept- und Zutatendatenbank (erweiterbar)
```

## 1. Server starten

### Lokal (Entwicklung)
```bash
cd server
npm test          # API-Tests
npm run dev       # http://localhost:8080
```
Ohne `JWT_SECRET` wird ein zufälliges Entwicklungs-Secret verwendet.

### Produktion (eigener Server / VPS mit Docker)
1. Richte eine Domain (z. B. `api.deinedomain.de`) per DNS-A-Record auf den Server.
2. Konfiguriere die Umgebung:
   ```bash
   cd server
   cp .env.example .env
   # DOMAIN=api.deinedomain.de
   # JWT_SECRET=$(openssl rand -hex 32)
   docker compose up -d
   ```
   Caddy besorgt automatisch ein Let's-Encrypt-Zertifikat. iOS verlangt HTTPS.
3. Prüfe: `curl https://api.deinedomain.de/health` → `{"status":"ok"}`

Die Daten liegen im Docker-Volume `api-data` (SQLite). Für Backups reicht das regelmäßige Sichern dieses Volumes.

**Sicherheit:** Passwörter werden mit scrypt gehasht. Access-Token (JWT, 15 min) und rotierende Refresh-Token (60 Tage, nur gehasht gespeichert) sind getrennt; wird ein Refresh-Token wiederverwendet, sperrt der Server die ganze Sitzung (Diebstahlerkennung). Login und Registrierung sind pro IP ratenbegrenzt. Logins mit unbekannter E-Mail dauern gleich lange wie mit bekannter, sodass sich über die Antwortzeit keine registrierten Adressen erraten lassen.

## 2. iOS-App bauen

Voraussetzungen: Mac mit **Xcode 16** oder neuer, iOS 17 oder neuer auf dem Gerät.

```bash
brew install xcodegen
cd ios
xcodegen generate
open Wochenleicht.xcodeproj
```

1. Wähle in Xcode unter *Signing & Capabilities* dein Team (Apple-ID genügt für das eigene Gerät).
2. **Server-Adresse:** in `ios/project.yml` unter `API_BASE_URL`:
   - `Debug`: `http://localhost:8080` (Simulator) bzw. `http://<IP-deines-Macs>:8080` (iPhone im WLAN)
   - `Release`: `https://api.deinedomain.de`

   Danach `xcodegen generate` erneut ausführen.
3. Starten. Beim ersten Start registrierst du dich, legst dein Profil an (daraus ergibt sich das Kalorienlimit), stellst Wasserziel und Tagesrhythmus ein, hakst deinen Gewürzvorrat ab und erlaubst Benachrichtigungen. Danach steht der Wochenplan.

### Tests
```bash
cd ios/WochenleichtCore && swift test     # Planer, Einkaufsliste, Vorrat, Wasser, Erinnerungen, Sync-Merge
cd server && npm test                     # Auth, Token-Rotation, Sync-Konflikte, Kontolöschung
```
Die GitHub-Actions-CI (`.github/workflows/ci.yml`) führt beide Testsuiten aus und baut die iOS-App auf einem macOS-Runner.

## Bekannte Grenzen & nächste Schritte

- **Passwort vergessen:** Dafür braucht es einen E-Mail-Versand (z. B. SMTP oder Postmark). Bis dahin lässt sich das Passwort nur in der App ändern, solange man angemeldet ist.
- **Erinnerungen** sind lokale Benachrichtigungen (iOS erlaubt höchstens 64 geplante). Die App plant jeweils 3 Tage im Voraus und erneuert die Planung bei jedem Öffnen und per Hintergrundaktualisierung. Wird die App länger nicht geöffnet, kommt der „Komm zurück“-Hinweis. Für Erinnerungen ohne Begrenzung wären Server-Push-Nachrichten (APNs) der nächste Schritt.
- **Supermarkt-Sortiment:** Ob ein Markt einen Artikel führt, ist nicht bekannt; die Zuordnung legst du selbst fest.
- **Rezeptdatenbank:** In `ios/WochenleichtCore/Sources/WochenleichtCore/Resources/` erweiterbar. Die kcal-Werte sind Richtwerte.
- **HealthKit** (Wasser/Gewicht in Apple Health schreiben) ist noch nicht angebunden.

> Wochenleicht ersetzt keine ärztliche Beratung. Bei Vorerkrankungen, in der Schwangerschaft oder bei Essstörungen bitte vor einer Diät ärztlich abklären lassen.
