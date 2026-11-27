import Foundation

/// Ein Eintrag im persönlichen Aussprache-Wörterbuch.
/// Korrekturen sind freiwillig: Ein Eintrag kann auch nur festhalten, dass ein Name geprüft wurde und passt.
public struct AusspracheEintrag: Codable, Identifiable, Equatable, Sendable {
    public enum Pruefung: String, Codable, Sendable {
        /// angehört und für gut befunden, keine Korrektur nötig
        case ok
        /// mit Lautschrift oder IPA korrigiert
        case korrigiert
    }

    public var id: UUID
    /// So wie der Name geschrieben wird, z. B. "Wojciechowski"
    public var schreibweise: String
    /// Deutsche Lautschrift (so schreiben, wie es klingen soll), z. B. "Woitschechowski"
    public var lautschrift: String
    /// Optional: Internationales Phonetisches Alphabet, z. B. "vɔjt͡ɕɛˈxɔfskʲi"
    public var ipa: String
    public var pruefung: Pruefung
    /// Stimme, mit der zuletzt geprüft wurde. Nach einem Stimmwechsel sollte neu angehört werden.
    public var gepruefteStimme: String?
    public var geprueftAm: Date

    public init(id: UUID = UUID(), schreibweise: String, lautschrift: String = "", ipa: String = "",
                pruefung: Pruefung, gepruefteStimme: String? = nil, geprueftAm: Date = Date()) {
        self.id = id
        self.schreibweise = schreibweise
        self.lautschrift = lautschrift
        self.ipa = ipa
        self.pruefung = pruefung
        self.gepruefteStimme = gepruefteStimme
        self.geprueftAm = geprueftAm
    }

    /// Hat der Eintrag eine Korrektur, die beim Sprechen angewendet werden muss?
    public var hatKorrektur: Bool {
        !lautschrift.trimmingCharacters(in: .whitespaces).isEmpty || !ipa.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Ein Stück Text, wie es an die Sprachausgabe geht.
public enum SprechTeil: Equatable, Sendable {
    case text(String)
    /// Ein Wort mit Korrektur: Original (für die Anzeige), Lautschrift-Ersatz und/oder IPA
    case korrigiert(original: String, lautschrift: String?, ipa: String?)
}

public enum Aussprache {
    /// Zerlegt einen Text und setzt die Korrekturen aus dem Wörterbuch ein.
    /// Gesucht wird ganzwortig und ohne Beachtung der Groß-/Kleinschreibung; längere Einträge haben Vorrang.
    public static func zerlege(_ text: String, lexikon: [AusspracheEintrag]) -> [SprechTeil] {
        let eintraege = lexikon.filter(\.hatKorrektur).sorted { $0.schreibweise.count > $1.schreibweise.count }
        var treffer: [(range: NSRange, eintrag: AusspracheEintrag)] = []
        let ns = text as NSString
        for e in eintraege {
            let wort = e.schreibweise.trimmingCharacters(in: .whitespaces)
            guard !wort.isEmpty else { continue }
            let muster = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: wort) + #"(?![\p{L}\p{N}])"#
            guard let re = try? NSRegularExpression(pattern: muster, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where !treffer.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
                treffer.append((m.range, e))
            }
        }
        treffer.sort { $0.range.location < $1.range.location }
        var teile: [SprechTeil] = []
        var pos = 0
        for t in treffer {
            if t.range.location > pos {
                teile.append(.text(ns.substring(with: NSRange(location: pos, length: t.range.location - pos))))
            }
            let laut = t.eintrag.lautschrift.trimmingCharacters(in: .whitespaces)
            let ipa = t.eintrag.ipa.trimmingCharacters(in: .whitespaces)
            teile.append(.korrigiert(original: ns.substring(with: t.range), lautschrift: laut.isEmpty ? nil : laut, ipa: ipa.isEmpty ? nil : ipa))
            pos = t.range.location + t.range.length
        }
        if pos < ns.length { teile.append(.text(ns.substring(from: pos))) }
        return teile
    }

    /// Text mit Lautschrift-Ersatz (für Stimmen ohne IPA-Unterstützung und zur Anzeige "so wird gesprochen").
    public static func gesprochenerText(_ teile: [SprechTeil]) -> String {
        teile.map {
            switch $0 {
            case .text(let t): t
            case .korrigiert(let o, let laut, _): laut ?? o
            }
        }.joined()
    }

    /// SSML für Cloud-Sprachdienste (Azure, Google, Amazon): IPA als `<phoneme>`, Lautschrift als `<sub>`.
    public static func ssml(_ teile: [SprechTeil], pauseMs: Int? = nil) -> String {
        var s = "<speak>"
        for t in teile {
            switch t {
            case .text(let x):
                s += xml(x)
            case .korrigiert(let o, _, let ipa?):
                s += "<phoneme alphabet=\"ipa\" ph=\"\(xml(ipa))\">\(xml(o))</phoneme>"
            case .korrigiert(let o, let laut?, nil):
                s += "<sub alias=\"\(xml(laut))\">\(xml(o))</sub>"
            case .korrigiert(let o, nil, nil):
                s += xml(o)
            }
        }
        if let pauseMs { s = s.replacingOccurrences(of: "<speak>", with: "<speak><break time=\"\(pauseMs)ms\"/>") }
        return s + "</speak>"
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Eintrag zu einer Schreibweise (ohne Beachtung der Groß-/Kleinschreibung).
    public static func eintrag(fuer name: String, in lexikon: [AusspracheEintrag]) -> AusspracheEintrag? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return lexikon.first { $0.schreibweise.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(n) == .orderedSame }
    }

    /// Fügt einen Eintrag hinzu oder ersetzt den bestehenden zur gleichen Schreibweise.
    public static func speichere(_ e: AusspracheEintrag, in lexikon: inout [AusspracheEintrag]) {
        if let i = lexikon.firstIndex(where: { $0.schreibweise.caseInsensitiveCompare(e.schreibweise) == .orderedSame }) {
            var neu = e
            neu.id = lexikon[i].id
            lexikon[i] = neu
        } else {
            lexikon.append(e)
        }
    }
}
