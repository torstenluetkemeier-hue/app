import Foundation

/// Textbausteine der Ansage. Platzhalter: `{{name}}`, bedingt: `{{#name}}…{{/name}}`, `{{^name}}…{{/name}}`.
public struct AnsageTexte: Codable, Equatable, Sendable {
    public var intro: String
    public var standard: String
    public var termin: String
    public var abwesend: String
    public var urlaub: String
    public var krank: String
    public var vertretung: String
    public var abschluss: String

    /// Einheitliche Firmenvorlage. Abweichungen sind möglich, werden in der App aber markiert.
    public static let firmenStandard = AnsageTexte(
        intro: "Guten Tag! Sie sind verbunden mit dem Anschluss von {{name}}{{#funktion}}, {{funktion}}{{/funktion}} bei {{firma}}, Ihrem Team für {{produkt}}.",
        standard: "Leider bin ich gerade nicht erreichbar.",
        termin: "Ich bin gerade {{grund}}{{#bis}}, {{bis}},{{/bis}} und daher nicht erreichbar.",
        abwesend: "Ich bin {{grund}}{{#bis}}, {{bis}},{{/bis}} und nur eingeschränkt erreichbar.",
        urlaub: "Ich bin im Urlaub{{#bis}}, {{bis}}{{/bis}}.",
        krank: "Ich bin derzeit leider nicht im Büro{{#bis}}, {{bis}}{{/bis}}.",
        vertretung: "In dringenden Fällen erreichen Sie {{vertretung}} unter {{vertretungTelefon}}.",
        abschluss: "Bitte hinterlassen Sie nach dem Signalton Ihren Namen, Ihre Rufnummer und Ihr Anliegen. Ich rufe Sie schnellstmöglich zurück. Vielen Dank für Ihren Anruf!"
    )

    public init(intro: String, standard: String, termin: String, abwesend: String, urlaub: String, krank: String, vertretung: String, abschluss: String) {
        self.intro = intro
        self.standard = standard
        self.termin = termin
        self.abwesend = abwesend
        self.urlaub = urlaub
        self.krank = krank
        self.vertretung = vertretung
        self.abschluss = abschluss
    }

    public func text(fuer modus: Modus) -> String {
        switch modus {
        case .standard: standard
        case .termin: termin
        case .abwesend: abwesend
        case .urlaub: urlaub
        case .krank: krank
        }
    }

    /// Für die Bearbeitung in der App.
    public static let felder: [(titel: String, keyPath: WritableKeyPath<AnsageTexte, String>)] = [
        ("Begrüßung & Vorstellung", \.intro),
        ("Nicht erreichbar", \.standard),
        ("Im Termin", \.termin),
        ("Unterwegs", \.abwesend),
        ("Urlaub", \.urlaub),
        ("Krank", \.krank),
        ("Hinweis auf Vertretung", \.vertretung),
        ("Abschluss", \.abschluss),
    ]

    public static let platzhalter = ["name", "vorname", "funktion", "firma", "produkt", "grund", "bis", "vertretung", "vertretungTelefon"]

    /// Anzahl der Bausteine, die vom Firmenstandard abweichen.
    public var abweichungenVomStandard: Int {
        Self.felder.filter { self[keyPath: $0.keyPath] != Self.firmenStandard[keyPath: $0.keyPath] }.count
    }
}

/// Minimaler Platzhalter-Renderer.
public enum Vorlage {
    public static func render(_ vorlage: String, _ werte: [String: String]) -> String {
        var out = vorlage
        let section = try! NSRegularExpression(pattern: #"\{\{([#^])\s*(\w+)\s*\}\}([\s\S]*?)\{\{/\s*\2\s*\}\}"#)
        var guardCount = 0
        while guardCount < 50, let m = section.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) {
            guardCount += 1
            let ns = out as NSString
            let typ = ns.substring(with: m.range(at: 1))
            let key = ns.substring(with: m.range(at: 2))
            let inner = ns.substring(with: m.range(at: 3))
            let gesetzt = !(werte[key] ?? "").isEmpty
            let ersetzung = (typ == "#") == gesetzt ? inner : ""
            out = ns.replacingCharacters(in: m.range, with: ersetzung)
        }
        let platzhalter = try! NSRegularExpression(pattern: #"\{\{\s*(\w+)\s*\}\}"#)
        var result = ""
        var last = out.startIndex
        for m in platzhalter.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            let r = Range(m.range, in: out)!
            let key = String(out[Range(m.range(at: 1), in: out)!])
            result += out[last..<r.lowerBound] + (werte[key] ?? "")
            last = r.upperBound
        }
        result += out[last...]
        return aufraeumen(result)
    }

    /// Leerräume und verwaiste Satzzeichen nach dem Einsetzen bereinigen.
    public static func aufraeumen(_ text: String) -> String {
        var t = text
        let regeln: [(String, String)] = [
            (#"\s+"#, " "),
            (#"\s+([,.!?:;])"#, "$1"),
            (#",\s*([.!?])"#, "$1"),
            (#"([.!?])\s*\."#, "$1"),
        ]
        for (muster, ersatz) in regeln {
            t = t.replacingOccurrences(of: muster, with: ersatz, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
