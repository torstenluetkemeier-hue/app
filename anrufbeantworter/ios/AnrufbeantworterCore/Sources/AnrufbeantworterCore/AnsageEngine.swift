import Foundation

public struct AktiverStatus: Equatable, Sendable {
    public enum Quelle: String, Sendable { case manuell, kalender, standard }
    public var status: Status
    public var quelle: Quelle
    public var kalenderEintragID: UUID?
}

public struct Ansage: Equatable, Sendable {
    public struct Abschnitt: Equatable, Sendable {
        public var teil: String
        public var text: String
    }
    public var abschnitte: [Abschnitt]
    public var status: AktiverStatus
    public var text: String { abschnitte.map(\.text).joined(separator: " ") }
}

public enum AnsageEngine {
    /// Reihenfolge: sofort gesetzter Status (solange nicht abgelaufen) > Kalendereintrag > Standard.
    public static func aktiverStatus(_ k: AppKonfiguration, jetzt: Date = Date()) -> AktiverStatus {
        if let s = k.status, istAktiv(s, jetzt: jetzt) {
            return AktiverStatus(status: s, quelle: .manuell)
        }
        let laufend = k.kalender
            .filter { Zeit.effektiverBeginn($0) <= jetzt && (Zeit.effektivesEnde($0.status).map { jetzt <= $0 } ?? false) }
            // Kürzere Einträge sind spezifischer (Termin während einer Dienstreise)
            .min { dauer($0) < dauer($1) }
        if let e = laufend {
            return AktiverStatus(status: e.status, quelle: .kalender, kalenderEintragID: e.id)
        }
        return AktiverStatus(status: Status(modus: .standard), quelle: .standard)
    }

    public static func istAktiv(_ s: Status, jetzt: Date) -> Bool {
        guard let ende = Zeit.effektivesEnde(s) else { return true }
        return jetzt <= ende
    }

    private static func dauer(_ e: KalenderEintrag) -> TimeInterval {
        (Zeit.effektivesEnde(e.status) ?? .distantFuture).timeIntervalSince(Zeit.effektiverBeginn(e))
    }

    public static func grund(_ s: Status) -> String {
        let frei = s.freitext.trimmingCharacters(in: .whitespaces)
        switch s.modus {
        case .termin: return s.terminArt == .sonstiges && !frei.isEmpty ? frei : s.terminArt.ansage
        case .abwesend: return s.abwesendArt == .sonstiges && !frei.isEmpty ? frei : s.abwesendArt.ansage
        default: return frei
        }
    }

    public static func vertretung(fuer s: Status, in k: AppKonfiguration) -> Vertretung? {
        switch s.vertretung {
        case .keine: return nil
        case .person(let id): return k.vertretungen.first { $0.id == id }
        case .automatisch:
            guard k.vertretungNennenIn.contains(s.modus), let id = k.standardVertretungID else { return nil }
            return k.vertretungen.first { $0.id == id }
        }
    }

    public static func erstelle(_ k: AppKonfiguration, jetzt: Date = Date()) -> Ansage {
        erstelle(k, status: aktiverStatus(k, jetzt: jetzt), jetzt: jetzt)
    }

    public static func erstelle(_ k: AppKonfiguration, status aktiv: AktiverStatus, jetzt: Date = Date()) -> Ansage {
        let s = aktiv.status
        let v = vertretung(fuer: s, in: k)
        let werte: [String: String] = [
            "name": k.profil.name,
            "vorname": k.profil.vorname,
            "funktion": k.profil.funktion,
            "firma": k.profil.firma,
            "produkt": k.profil.produkt,
            "grund": grund(s),
            "bis": Zeit.bisText(s.bis, ganztags: s.modus.istGanztaegig, jetzt: jetzt),
            "vertretung": v?.name ?? "",
            "vertretungTelefon": v.map { Rufnummer.zumSprechen($0.telefon) } ?? "",
        ]
        var abschnitte: [Ansage.Abschnitt] = []
        func add(_ teil: String, _ vorlage: String) {
            let t = Vorlage.render(vorlage, werte)
            if !t.isEmpty { abschnitte.append(.init(teil: teil, text: t)) }
        }
        add("Begrüßung", k.texte.intro)
        add("Status", k.texte.text(fuer: s.modus))
        if v != nil { add("Vertretung", k.texte.vertretung) }
        add("Abschluss", k.texte.abschluss)
        return Ansage(abschnitte: abschnitte, status: aktiv)
    }
}

public enum Rufnummer {
    /// Ziffern einzeln, in Gruppen mit Pausen: "0 3 6 4 1, 0 0 0, 2 0 0"
    public static func zumSprechen(_ roh: String) -> String {
        var s = roh.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("+49") {
            s = "0" + s.dropFirst(3).drop { " /-()".contains($0) }
        }
        let plus = s.hasPrefix("+")
        let gruppen = s.split(whereSeparator: { " /-()".contains($0) })
            .map { $0.filter(\.isNumber) }
            .filter { !$0.isEmpty }
        let teile: [String]
        if gruppen.count > 1 {
            teile = gruppen
        } else {
            let alle = Array(gruppen.first ?? "")
            teile = stride(from: 0, to: alle.count, by: 3).map { String(alle[$0..<min($0 + 3, alle.count)]) }
        }
        return (plus ? "plus " : "") + teile.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}
