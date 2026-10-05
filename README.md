# Wochenleicht – nachhaltig abnehmen (iPhone & iPad)

Wochenleicht plant deine Mahlzeiten immer **eine ganze Woche im Voraus**, hält dabei deine **Kalorienobergrenze** ein, schreibt **Einkaufslisten pro Supermarkt in deiner Nähe**, merkt sich deinen **Vorrat inklusive Restmengen** nach jedem Einkauf, protokolliert dein **Wasser (mind. 3 Liter/Tag)** und **erinnert dich hartnäckig** daran, dranzubleiben. Ohne Registrierung per E-Mail und Passwort geht es nicht los.

**Alles läuft auf dem iPhone bzw. iPad:** Konten, Passwortprüfung und sämtliche Daten liegen ausschließlich auf dem Gerät. Es gibt keinen externen Server, kein Hosting und keine Internetpflicht. Nur die Supermarktsuche nutzt Apple Karten.

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
| Registrierung per E-Mail + Passwort | Pflicht beim ersten Start, **lokal auf dem Gerät**. Passwörter werden mit PBKDF2-SHA256 (210.000 Runden, zufälliges Salt) gehasht und nie im Klartext gespeichert. Nach 5 Fehlversuchen wird der Login 60 Sekunden gesperrt. Mehrere Konten pro Gerät sind möglich, jedes mit eigenen Daten. Passwort ändern, abmelden und **Konto löschen** (App-Store-Pflicht) gehen in der App. |
| iPhone + iPad | Universelle App. Auf dem iPad erscheint der Wochenplan als Kartenraster. Jedes Gerät hat seine eigenen Konten und Daten; einen Abgleich zwischen den Geräten gibt es nicht. |

## Projektstruktur

```
ios/
  project.yml            XcodeGen-Projektdefinition
  App/                   SwiftUI-App (Views, Services, AppModel)
    Services/AuthService.swift, PBKDF2Hasher.swift   Lokale Anmeldung
  WochenleichtCore/      Plattformunabhängige Logik als Swift Package + Unit-Tests
    Accounts.swift       Kontoverwaltung (Registrierung, Login, Sperre, Passwortwechsel)
    Resources/recipes.json, ingredients.json   Rezept- und Zutatendatenbank (erweiterbar)
```

## iOS-App bauen

Voraussetzungen: Mac mit **Xcode 16** oder neuer, iOS 17 oder neuer auf dem Gerät.

```bash
brew install xcodegen
cd ios
xcodegen generate
open Wochenleicht.xcodeproj
```

1. Wähle in Xcode unter *Signing & Capabilities* dein Team (Apple-ID genügt für das eigene Gerät).
2. Starten. Beim ersten Start registrierst du dich, legst dein Profil an (daraus ergibt sich das Kalorienlimit), stellst Wasserziel und Tagesrhythmus ein, hakst deinen Gewürzvorrat ab und erlaubst Benachrichtigungen. Danach steht der Wochenplan.

### Tests
```bash
cd ios/WochenleichtCore && swift test     # Konten, Planer, Einkaufsliste, Vorrat, Wasser, Erinnerungen
```
Die GitHub-Actions-CI (`.github/workflows/ci.yml`) führt die Tests aus und baut die iOS-App auf einem macOS-Runner.

## Bekannte Grenzen & nächste Schritte

- **Passwort vergessen:** Ohne Server gibt es keine Wiederherstellung per E-Mail. „Passwort vergessen?“ im Login löscht nach einer Warnung das lokale Konto samt Daten, danach kann man sich neu registrieren.
- **Kein Abgleich iPhone ↔ iPad und kein Backup außerhalb des Geräts** (außer über das normale iPhone-Backup). Ein späterer Abgleich über iCloud ist möglich; die Zusammenführungslogik (`AppData.merged`) ist bereits vorhanden, braucht aber ein kostenpflichtiges Apple-Developer-Konto.
- **Erinnerungen** sind lokale Benachrichtigungen (iOS erlaubt höchstens 64 geplante). Die App plant jeweils 3 Tage im Voraus und erneuert die Planung bei jedem Öffnen und per Hintergrundaktualisierung. Wird die App länger nicht geöffnet, kommt der „Komm zurück“-Hinweis.
- **Supermarkt-Sortiment:** Ob ein Markt einen Artikel führt, ist nicht bekannt; die Zuordnung legst du selbst fest.
- **Rezeptdatenbank:** In `ios/WochenleichtCore/Sources/WochenleichtCore/Resources/` erweiterbar. Die kcal-Werte sind Richtwerte.
- **HealthKit** (Wasser/Gewicht in Apple Health schreiben) ist noch nicht angebunden.

> Wochenleicht ersetzt keine ärztliche Beratung. Bei Vorerkrankungen, in der Schwangerschaft oder bei Essstörungen bitte vor einer Diät ärztlich abklären lassen.
