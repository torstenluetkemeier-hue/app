import Foundation

/// Welche Namen in der Ansage vorkommen und ob ihre Aussprache geprüft wurde.
public struct NamensKandidat: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case ungeprueft, ok, korrigiert
        /// Geprüft, aber mit einer anderen Stimme
        case stimmeGeaendert
    }

    public var id: String { name.lowercased() }
    public var name: String
    /// z. B. "Mein Name", "Vertretung", "Firma", "Testname"
    public var herkunft: String
    /// Satz, in dem der Name zum Probehören gesprochen wird
    public var kontextSatz: String
    public var risiko: AusspracheRisiko.Bewertung
    public var status: Status

    public var brauchtAufmerksamkeit: Bool {
        (status == .ungeprueft || status == .stimmeGeaendert) && risiko.stufe >= .mittel
    }
}

public enum NamensPruefung {
    /// Eingebaute Testnamen, um eine Stimme mit schwierigen Namen auszuprobieren.
    public static let beispielNamen = [
        "Krzysztof Szczepański", "Gülşen Yılmaz", "Nguyen Thi Huong", "Jacques Dubois", "Giulia Ciccone",
        "Siobhan O'Connor", "Wojciechowski", "Xiao Zhang", "Joaquín García", "Ruud van Nistelrooij", "MVZ", "tomedo",
    ]

    public static func kandidaten(_ k: AppKonfiguration, stimmeID: String?) -> [NamensKandidat] {
        var liste: [NamensKandidat] = []
        func add(_ name: String, _ herkunft: String, _ satz: String) {
            let n = name.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !liste.contains(where: { $0.id == n.lowercased() }) else { return }
            liste.append(NamensKandidat(name: n, herkunft: herkunft, kontextSatz: satz,
                                        risiko: AusspracheRisiko.bewerte(n), status: status(n, k.lexikon, stimmeID: stimmeID)))
        }
        add(k.profil.name, "Mein Name", "Sie sind verbunden mit dem Anschluss von \(k.profil.name).")
        for v in k.vertretungen {
            add(v.name, "Vertretung", "In dringenden Fällen erreichen Sie \(v.name).")
        }
        add(k.profil.firma, "Firma", "Sie sind verbunden mit \(k.profil.firma).")
        add(k.profil.produkt, "Produkt", "Ihr Team für \(k.profil.produkt).")
        for t in k.testnamen {
            add(t, "Testname", "Guten Tag, ich verbinde Sie mit \(t).")
        }
        return liste
    }

    public static func status(_ name: String, _ lexikon: [AusspracheEintrag], stimmeID: String?) -> NamensKandidat.Status {
        guard let e = Aussprache.eintrag(fuer: name, in: lexikon) else { return .ungeprueft }
        if let s = e.gepruefteStimme, let aktuell = stimmeID, s != aktuell { return .stimmeGeaendert }
        return e.pruefung == .ok ? .ok : .korrigiert
    }

    /// Namen, auf die vor dem Aktivieren hingewiesen wird (Hinweis, kein Zwang).
    public static func offeneHinweise(_ k: AppKonfiguration, stimmeID: String?) -> [NamensKandidat] {
        kandidaten(k, stimmeID: stimmeID).filter { $0.brauchtAufmerksamkeit && $0.herkunft != "Testname" }
    }

    /// Neue Namen gegenüber einer früheren Konfiguration (für die freiwillige Rückfrage).
    public static func neueNamen(alt: AppKonfiguration, neu: AppKonfiguration) -> [String] {
        let vorher = Set(kandidaten(alt, stimmeID: nil).map(\.id))
        return kandidaten(neu, stimmeID: nil)
            .filter { !vorher.contains($0.id) && $0.status == .ungeprueft && $0.herkunft != "Testname" }
            .map(\.name)
    }
}
