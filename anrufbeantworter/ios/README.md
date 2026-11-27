# Anrufbeantworter – iPhone-App

Die App erzeugt die einheitliche zollsoft-Ansage mit einer angenehmen Stimme und hält sie aktuell. Sie funktioniert allein über die Mailbox oder zusammen mit dem **Cloud-Anrufbeantworter** (Rufumleitung, siehe unten). Eine Anbindung an die Firmen-Telefonanlage ist nicht nötig.

> **Wichtig:** Apple erlaubt keiner App, Anrufe selbst anzunehmen. Angenommen wird deshalb immer von der **Mailbox** (iPhone-Voicemail oder Mailbox des Netzbetreibers). Die App liefert die fertige Ansage als Audio und erinnert, wenn eine andere Ansage fällig ist. Details stehen in der App unter *Ansage › Ansage in die Mailbox bringen*.

## Funktionen

| Bereich | Was die App kann |
|---|---|
| **Ansage** | Einheitlich aus der Firmenvorlage: „Guten Tag! Sie sind verbunden mit dem Anschluss von Max Meyer, Kundenberater bei zollsoft, Ihrem Team für tomedo. …“ Anhören, als `.m4a` teilen, mit Countdown zum Aufsprechen abspielen. |
| **Status** | Sofort: Nicht erreichbar, im Termin (Online-Präsentation, Präsentation vor Ort, Schulung, Webinar, Kundentermin, Installation, Besprechung, Gespräch, Freitext), unterwegs, Urlaub, krank. Jeweils mit Ende und Vertretung. Zusätzlich vorgeplante Einträge mit Erinnerung zu Beginn und Ende. |
| **Vertretung** | Mehrere Vertretungen, eine Standard-Vertretung, die je Status automatisch genannt wird. Die Rufnummer wird Ziffer für Ziffer gesprochen. |
| **Stimme** | Alle deutschen iOS-Stimmen, beste Qualität zuerst (Premium/Erweitert), Tempo, Tonhöhe, Pausen. Firmenstandard per Knopfdruck. Optional die eigene Stimme (*Personal Voice*). |
| **Texte** | Bausteine mit Platzhaltern. Abweichungen vom Firmenstandard werden markiert und lassen sich zurücksetzen. |
| **Aussprache** | Siehe unten. |

## Cloud-Anrufbeantworter (empfohlen)

Läuft komplett bei deutschen Anbietern. Die Telefonie macht sipgate, die Ansage besteht aus deinen **eigenen Aufnahmen**. Nur der Name eines erkannten Anrufers wird von der KI in deiner Stimme ergänzt. Einstellen unter *Einstellungen › Cloud-Anrufbeantworter*:

1. **Verbinden:** Server-Adresse und persönlichen Zugangsschlüssel eintragen. Die App speichert den Schlüssel im Schlüsselbund.
2. **Meine Aufnahmen:** Liste der benötigten Bausteine („Guten Tag!“, Vorstellung, Status-Sätze, Vertretung, Abschluss …). Tippen, Text groß ablesen, aufnehmen (mit Pegelanzeige), anhören, *Verwenden*. Stille wird abgeschnitten und die Lautstärke angeglichen. Ändert sich ein Text, wird die Aufnahme als veraltet markiert. *So klingt die KI in deiner Stimme* spielt einen Testsatz.
3. **Rufumleitung:** Codes für Nichtannahme (mit Klingeldauer), besetzt und nicht erreichbar, jeweils mit Kopier-Knopf. In der Telefon-App einfügen, denn iOS erlaubt Apps das Wählen von `*`/`#`-Codes nicht.
4. **Aktivieren:** Ab dann überträgt die App jede Änderung an Status, Kalender, Texten und Wörterbuch automatisch.
5. **Testen:** *Wie am Telefon anhören* spielt genau die Datei ab, die Anrufer hören, auch als „bekannter Kunde“.
6. **Anrufe:** Tab mit erkanntem Anrufer, Hinweis „Nachricht in der sipgate-Mailbox“, Zurückrufen, Erledigt.

Für die Mailbox-Variante ohne Server erzeugt die App die Ansage weiterhin mit einer iOS-Stimme. Wer das nicht möchte, nutzt den Cloud-Anrufbeantworter.

## Aussprache-Prüfung

Ziel: Auch schwierige Namen (Szczepański, Yılmaz, Nguyen, Siobhan …) sollen richtig klingen. Prüfen und Korrigieren sind **freiwillig**.

1. **Prüfliste:** Alle Namen, die in der Ansage vorkommen (eigener Name, Vertretungen, Firma, Produkt), plus frei wählbare Testnamen. Bei jedem Namen steht, ob er angehört, korrigiert oder noch offen ist.
2. **Risiko-Einschätzung:** Die App erkennt Namen, die deutsche Stimmen oft falsch sprechen (polnische, tschechische, türkische, französische, italienische, spanische, englische, niederländische, vietnamesische, chinesische und irische Schreibweisen, Abkürzungen, Apostrophe) und nennt den Grund. Gängige deutsche Namen bleiben unauffällig.
3. **Anhören:** Im Satz („… erreichen Sie Gülşen Yılmaz …“) oder einzeln. Danach entscheidest du: *Klingt richtig* oder *Klingt falsch – korrigieren*.
4. **Korrigieren**, drei Wege:
   - **Vorschläge** zum Anhören: bewährte Lautschrift für bekannte Namen, Umschrift nach erkannter Herkunft, Abkürzung buchstabiert, in Silben.
   - **Eigene Lautschrift:** so schreiben, wie es klingen soll („Woitschechowski“).
   - **IPA** für Profis, mit Betonung und Zeichenleiste (iOS wendet IPA direkt auf das Wort an).
5. **Wörterbuch:** Korrekturen gelten überall in der Ansage, ganzwortig, ohne Beachtung der Groß-/Kleinschreibung. Ein „passt“ ohne Korrektur wird ebenfalls gemerkt.
6. **Rückfragen statt Zwang:** Kommt ein neuer, auffälliger Name dazu, fragt die App: *Jetzt anhören / Später / Nicht mehr fragen*. Vor dem Export erscheint ein Hinweis auf offene Namen; *Trotzdem exportieren* geht immer.
7. **Stimmwechsel:** Wurde ein Name mit einer anderen Stimme geprüft, empfiehlt die App, ihn erneut anzuhören.
8. **Stimmen-Test:** Ein Satz schwieriger Beispielnamen zeigt schnell, wie gut eine Stimme damit umgeht.

## Bauen

Voraussetzungen: Mac mit **Xcode 16** oder neuer, iOS 17 oder neuer auf dem Gerät.

```bash
brew install xcodegen
cd anrufbeantworter/ios
xcodegen generate
open Anrufbeantworter.xcodeproj
```

In Xcode unter *Signing & Capabilities* das eigene Team wählen und auf dem iPhone starten.

**Tests der Kernlogik** (laufen auch unter Linux, ohne Xcode):

```bash
cd anrufbeantworter/ios/AnrufbeantworterCore
swift test     # 30 Tests: Ansage, Status, Kalender, Aussprache, Risiko, Vorschläge, Cloud-Übertragung, Umleitungscodes
```

## Aufbau

```
ios/
  project.yml                 XcodeGen-Projekt
  App/                        SwiftUI-App
    AppModel.swift            Zustand, Speichern, Aussprache-Aktionen
    Services/Sprecher.swift   iOS-Sprachausgabe inkl. IPA/Lautschrift
    Services/AudioExport.swift  Ansage → .m4a
    Services/Speicher.swift   Speicherung auf dem Gerät + Erinnerungen
    Views/                    Ansage, Status, Aussprache, Einstellungen
  AnrufbeantworterCore/       Plattformunabhängige Logik + Tests
    AnsageEngine.swift        Status ermitteln, Ansage zusammensetzen
    AnsageTexte.swift         Firmenvorlage, Platzhalter-Renderer
    Aussprache.swift          Wörterbuch anwenden, SSML für Cloud-Stimmen
    AusspracheRisiko.swift    Risiko-Einschätzung, Lautschrift-Vorschläge
    NamensPruefung.swift      Prüfliste, Status je Name, neue Namen
```

Das Aussprache-Wörterbuch lässt sich auch als **SSML** ausgeben (`<phoneme>`/`<sub>`). Damit kann die spätere Cloud-Ausbaustufe dieselben Korrekturen mit Cloud-Stimmen verwenden.
