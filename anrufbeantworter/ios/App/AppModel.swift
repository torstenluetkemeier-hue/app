import SwiftUI
import AnrufbeantworterCore

@MainActor
@Observable
final class AppModel {
    var konfig: AppKonfiguration {
        didSet {
            speicher.speichern(konfig)
            if konfig.status != oldValue.status || konfig.kalender != oldValue.kalender || konfig.cloudAktiv != oldValue.cloudAktiv {
                // Mit Cloud-Anrufbeantworter wechselt die Ansage selbst, Erinnerungen sind dann überflüssig.
                if konfig.cloudAktiv { Erinnerungen.alleEntfernen() } else { Erinnerungen.planen(konfig) }
            }
            cloud.planeUebertragung(konfig)
        }
    }

    /// Neu hinzugekommene Namen, zu denen freiwillig eine Aussprache-Prüfung angeboten wird
    var ausspracheFrage: [String] = []
    /// Namen, die gerade im Prüfablauf angehört werden sollen
    var pruefAuftrag: [String]?

    let sprecher = Sprecher()
    let cloud = CloudDienst()

    @ObservationIgnored private let speicher = Speicher()
    /// Stand, gegen den neue Namen erkannt werden
    @ObservationIgnored private var namensStand: AppKonfiguration

    init() {
        let k = Speicher().laden() ?? AppKonfiguration()
        konfig = k
        namensStand = k
        if k.cloudAktiv {
            let dienst = cloud
            Task { await dienst.uebertragen(k) }
        }
    }

    // MARK: Ansage

    func ansage(jetzt: Date = Date()) -> Ansage { AnsageEngine.erstelle(konfig, jetzt: jetzt) }

    func ansageAnhoeren() {
        sprecher.sprich(abschnitte: ansage().abschnitte.map(\.text), einstellung: konfig.stimme, lexikon: konfig.lexikon)
    }

    /// Kennung der tatsächlich verwendeten Stimme (auch wenn "automatisch" gewählt ist)
    var aktiveStimmeID: String? { Sprecher.stimme(konfig.stimme.stimmeID)?.identifier }

    var offeneNamensHinweise: [NamensKandidat] { NamensPruefung.offeneHinweise(konfig, stimmeID: aktiveStimmeID) }

    // MARK: Aussprache

    /// Spricht einen Text; optional mit einer probeweisen Korrektur für einen Namen (noch nicht gespeichert).
    func sprich(_ text: String, probe: AusspracheEintrag? = nil) {
        var lex = konfig.lexikon
        if let probe {
            lex.removeAll { $0.schreibweise.caseInsensitiveCompare(probe.schreibweise) == .orderedSame }
            lex.append(probe)
        }
        sprecher.sprich(text, einstellung: konfig.stimme, lexikon: lex)
    }

    func markiereRichtig(_ name: String) {
        Aussprache.speichere(AusspracheEintrag(schreibweise: name, pruefung: .ok, gepruefteStimme: aktiveStimmeID), in: &konfig.lexikon)
    }

    func speichereKorrektur(_ name: String, lautschrift: String, ipa: String) {
        let e = AusspracheEintrag(schreibweise: name, lautschrift: lautschrift, ipa: ipa, pruefung: .korrigiert, gepruefteStimme: aktiveStimmeID)
        if e.hatKorrektur {
            Aussprache.speichere(e, in: &konfig.lexikon)
        } else {
            markiereRichtig(name)
        }
    }

    func entferneEintrag(_ name: String) {
        konfig.lexikon.removeAll { $0.schreibweise.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Nach dem Bearbeiten von Profil oder Vertretungen: neue Namen erkennen und (freiwillig) Prüfung anbieten.
    func pruefeNeueNamen() {
        defer { namensStand = konfig }
        guard konfig.nachAusspracheFragen else { return }
        let neu = NamensPruefung.neueNamen(alt: namensStand, neu: konfig)
            .filter { AusspracheRisiko.bewerte($0).stufe >= .mittel || konfig.lexikon.isEmpty }
        if !neu.isEmpty { ausspracheFrage = neu }
    }
}
