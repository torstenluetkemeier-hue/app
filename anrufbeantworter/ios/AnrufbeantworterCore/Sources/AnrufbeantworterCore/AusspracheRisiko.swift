import Foundation

/// Schätzt ab, ob eine deutsche Stimme einen Namen vermutlich falsch ausspricht,
/// und schlägt Lautschrift-Varianten zum Anhören vor. Entschieden wird immer per Gehör.
public enum AusspracheRisiko {
    public enum Stufe: Int, Comparable, Sendable {
        case gering = 0, mittel = 1, hoch = 2
        public static func < (a: Stufe, b: Stufe) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .gering: "vermutlich unproblematisch"
            case .mittel: "bitte einmal anhören"
            case .hoch: "wird oft falsch gesprochen"
            }
        }
    }

    public enum Herkunft: String, CaseIterable, Sendable {
        case polnisch, tschechisch, tuerkisch, franzoesisch, italienisch, spanisch, englisch, niederlaendisch, vietnamesisch, chinesisch, irisch, sonstige
        public var label: String {
            switch self {
            case .polnisch: "polnisch"
            case .tschechisch: "tschechisch/slowakisch"
            case .tuerkisch: "türkisch"
            case .franzoesisch: "französisch"
            case .italienisch: "italienisch"
            case .spanisch: "spanisch/portugiesisch"
            case .englisch: "englisch"
            case .niederlaendisch: "niederländisch"
            case .vietnamesisch: "vietnamesisch"
            case .chinesisch: "chinesisch"
            case .irisch: "irisch"
            case .sonstige: "andere Sprache"
            }
        }
    }

    public struct Bewertung: Hashable, Sendable {
        public var stufe: Stufe
        public var gruende: [String]
        public var herkunft: [Herkunft]
    }

    public struct Vorschlag: Hashable, Sendable {
        public var lautschrift: String
        public var beschreibung: String
    }

    // MARK: - Erkennung

    /// Merkmale werden je Wort (kleingeschrieben) geprüft. Bewusst zurückhaltend,
    /// damit gängige deutsche Namen (Thomas, Müller, Wagner, Christian …) nicht auffallen.
    private struct Merkmal {
        let muster: String
        let herkunft: Herkunft
        let gewicht: Int
        let grund: String
    }

    private static let merkmale: [Merkmal] = [
        .init(muster: "[ąęłńśźż]", herkunft: .polnisch, gewicht: 3, grund: "polnische Sonderzeichen"),
        .init(muster: "(szcz|cz|sz|rz|wicz|dzi|ci[aeou]|^wojc)", herkunft: .polnisch, gewicht: 2, grund: "polnische Buchstabenfolge (cz, sz, rz …)"),
        .init(muster: "[čřšžěůťďň]", herkunft: .tschechisch, gewicht: 3, grund: "tschechische Sonderzeichen"),
        .init(muster: "[çşğı]", herkunft: .tuerkisch, gewicht: 3, grund: "türkische Sonderzeichen"),
        .init(muster: "o[gğ]lu$", herkunft: .tuerkisch, gewicht: 2, grund: "türkische Endung -oğlu"),
        .init(muster: "[éèêëàâîïôûœ]", herkunft: .franzoesisch, gewicht: 2, grund: "französische Akzente"),
        .init(muster: "(eau|eux|oux|ault|ois$|ier$|^jacq|^jean$|^fran[cç]ois)", herkunft: .franzoesisch, gewicht: 2, grund: "französische Schreibweise"),
        .init(muster: "(cci|cce|gli|^ci|^ce|^gi[aou]|^giu)", herkunft: .italienisch, gewicht: 2, grund: "italienische Schreibweise (c/g vor e/i)"),
        .init(muster: "[ñãõíáú]", herkunft: .spanisch, gewicht: 2, grund: "spanische/portugiesische Zeichen"),
        .init(muster: "(^ll|ão$|^joaq|^ju[al]n|^xim)", herkunft: .spanisch, gewicht: 2, grund: "spanische/portugiesische Schreibweise"),
        .init(muster: "(sh|^mc|wr|igh|ough|^o'|^o’)", herkunft: .englisch, gewicht: 1, grund: "englische Schreibweise"),
        .init(muster: "(ij$|ij[^a-z]|ooij|^van$|^ter$|^ten$)", herkunft: .niederlaendisch, gewicht: 1, grund: "niederländische Schreibweise"),
        .init(muster: "[ơưăđạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]", herkunft: .vietnamesisch, gewicht: 3, grund: "vietnamesische Zeichen"),
        .init(muster: "^(nguy|ngo$|pham$|tran$|huynh$|thi$)", herkunft: .vietnamesisch, gewicht: 3, grund: "vietnamesischer Name"),
        .init(muster: "^(x[iu]|zh|q[^u]|xiao)", herkunft: .chinesisch, gewicht: 3, grund: "chinesische Umschrift (Pinyin)"),
        .init(muster: "(siobh|niamh|saoirse|aoife|caoim|^sean$|^seán$)", herkunft: .irisch, gewicht: 3, grund: "irische Schreibweise"),
        .init(muster: "(ovi[cć]$|evi[cć]$|enko$|escu$|yan$)", herkunft: .sonstige, gewicht: 1, grund: "osteuropäische/armenische Endung"),
    ]

    /// Bekannte Namen mit bewährter Lautschrift für deutsche Stimmen.
    public static let bekannteNamen: [String: String] = [
        "nguyen": "Nuien", "pham": "Fahm", "tran": "Tschan", "huynh": "Huin", "thi": "Ti",
        "xiao": "Schiau", "zhang": "Dschang", "zhou": "Dschou", "qian": "Tschjen", "xu": "Schü",
        "wojciech": "Woitschech", "wojciechowski": "Woitschechowski", "krzysztof": "Kschischtof",
        "szczepański": "Schtschepanski", "szczepanski": "Schtschepanski", "łukasz": "Wukasch", "małgorzata": "Mauwgoschata",
        "jacques": "Schack", "jean": "Schong", "françois": "Frangsoa", "dubois": "Düboa",
        "siobhan": "Schiwohn", "niamh": "Niehw", "saoirse": "Sörscha", "aoife": "Iefa", "seán": "Schaun", "sean": "Schaun",
        "joaquín": "Choakin", "joaquin": "Choakin", "giulia": "Dschulia", "giovanni": "Dschowanni", "ciccone": "Tschikone",
        "çelik": "Tschelik", "yılmaz": "Jilmas", "gülşen": "Gülschen", "şahin": "Schahin", "doğan": "Doan",
    ]

    public static func bewerte(_ name: String) -> Bewertung {
        var punkte = 0
        var gruende: [String] = []
        var herkunft: [Herkunft] = []
        for wort in teilwoerter(name) {
            let lower = wort.lowercased()
            for m in merkmale where lower.range(of: m.muster, options: .regularExpression) != nil {
                punkte += m.gewicht
                if !gruende.contains(m.grund) { gruende.append(m.grund) }
                if !herkunft.contains(m.herkunft) { herkunft.append(m.herkunft) }
            }
            if bekannteNamen[lower] != nil {
                punkte += 2
                gruende.append("„\(wort)“ wird von deutschen Stimmen häufig falsch gesprochen")
            }
            if wort.count >= 2, wort.count <= 5, wort == wort.uppercased(), wort.rangeOfCharacter(from: .letters) != nil {
                punkte += 1
                gruende.append("Abkürzung „\(wort)“: wird evtl. als Wort gelesen statt buchstabiert")
            }
        }
        if name.contains("'") || name.contains("’") {
            punkte += 1
            gruende.append("Apostroph im Namen")
        }
        let stufe: Stufe = punkte >= 3 ? .hoch : punkte >= 1 ? .mittel : .gering
        return Bewertung(stufe: stufe, gruende: gruende, herkunft: herkunft)
    }

    // MARK: - Vorschläge

    /// Lautschrift-Vorschläge zum Anhören. Nichts wird automatisch übernommen.
    public static func vorschlaege(_ name: String, maximal: Int = 5) -> [Vorschlag] {
        var ergebnis: [Vorschlag] = []
        func add(_ text: String, _ beschreibung: String) {
            let t = Vorlage.aufraeumen(text)
            guard !t.isEmpty, t.lowercased() != name.lowercased(),
                  !ergebnis.contains(where: { $0.lautschrift.lowercased() == t.lowercased() }) else { return }
            ergebnis.append(Vorschlag(lautschrift: t, beschreibung: beschreibung))
        }

        // 1. Bekannte Namen ersetzen (auch Teile von Doppelnamen)
        let bekannt = ersetzeTeile(name) { bekannteNamen[$0.lowercased()] }
        if bekannt != name { add(bekannt, "bewährte Lautschrift") }

        // 2. Umschrift nach erkannter Herkunft
        for h in bewerte(name).herkunft where regeln[h] != nil {
            add(umschreiben(name, h), "\(h.label) gelesen")
        }

        // 3. Abkürzungen buchstabieren
        add(ersetzeTeile(name) { w in
            w.count >= 2 && w.count <= 5 && w == w.uppercased() && w.rangeOfCharacter(from: .letters) != nil
                ? w.map(String.init).joined(separator: " ") : nil
        }, "Abkürzung buchstabiert")

        // 4. In Silben (hilft bei langen, zusammengezogenen Namen)
        guard bewerte(name).stufe > .gering || !ergebnis.isEmpty else { return ergebnis }
        let basis = ergebnis.first?.lautschrift ?? name
        add(ersetzeTeile(basis) { $0.count > 7 ? silbenTrennen($0) : nil }, "langsamer, in Silben")

        return Array(ergebnis.prefix(maximal))
    }

    // MARK: - Umschrift

    private enum Ort { case ueberall, anfang, ende }
    private struct Regel {
        let von: String
        let nach: String
        let ort: Ort
        init(_ von: String, _ nach: String, _ ort: Ort = .ueberall) {
            self.von = von
            self.nach = nach
            self.ort = ort
        }
    }

    /// Regeln je Sprache. Angewendet in EINEM Durchlauf von links nach rechts:
    /// An jeder Stelle gewinnt die erste passende Regel, Ersetzungen werden nicht erneut ersetzt.
    private static let regeln: [Herkunft: [Regel]] = [
        .polnisch: [
            Regel("szcz", "schtsch"), Regel("wicz", "witsch"), Regel("ów", "uf", .ende), Regel("cz", "tsch"), Regel("sz", "sch"), Regel("rz", "sch"),
            Regel("dzi", "dschi"), Regel("cia", "tscha"), Regel("cie", "tsche"), Regel("cio", "tscho"), Regel("ciu", "tschu"), Regel("ci", "tschi"),
            Regel("sia", "scha"), Regel("sie", "sche"), Regel("sio", "scho"), Regel("si", "schi"), Regel("nia", "nja"), Regel("nie", "nje"),
            Regel("ł", "w"), Regel("ś", "sch"), Regel("ć", "tsch"), Regel("ń", "n"), Regel("ó", "u"), Regel("ż", "sch"), Regel("ź", "sch"),
            Regel("ą", "on"), Regel("ę", "en"), Regel("oj", "oi"), Regel("aj", "ai"), Regel("ej", "ei"), Regel("y", "i"), Regel("w", "f", .ende),
        ],
        .tschechisch: [
            Regel("ch", "ch"), Regel("č", "tsch"), Regel("š", "sch"), Regel("ž", "sch"), Regel("ř", "rsch"), Regel("ě", "je"),
            Regel("ů", "u"), Regel("ň", "nj"), Regel("ť", "tj"), Regel("ď", "dj"), Regel("c", "z"), Regel("y", "i"),
        ],
        .tuerkisch: [
            Regel("oğlu", "olu", .ende), Regel("oglu", "olu", .ende), Regel("ç", "tsch"), Regel("ş", "sch"), Regel("ğ", ""), Regel("ı", "e"),
            Regel("c", "dsch"), Regel("z", "s"), Regel("y", "j"), Regel("v", "w"),
        ],
        .franzoesisch: [
            Regel("eaux", "o"), Regel("eau", "o"), Regel("aux", "o"), Regel("ault", "o"), Regel("oux", "u"), Regel("ou", "u"),
            Regel("ois", "oa", .ende), Regel("ais", "ä", .ende), Regel("ait", "ä", .ende), Regel("et", "ä", .ende), Regel("ier", "jeh", .ende),
            Regel("oi", "oa"), Regel("ain", "äng"), Regel("ein", "äng"), Regel("gn", "nj"), Regel("ch", "sch"), Regel("qu", "k"), Regel("j", "sch"),
            Regel("é", "e"), Regel("è", "ä"), Regel("ê", "ä"), Regel("ç", "s"), Regel("u", "ü"),
            Regel("es", "", .ende), Regel("e", "", .ende), Regel("s", "", .ende), Regel("t", "", .ende), Regel("x", "", .ende),
        ],
        .italienisch: [
            Regel("cch", "k"), Regel("cci", "tschi"), Regel("cce", "tsche"), Regel("cia", "tscha"), Regel("cio", "tscho"), Regel("ciu", "tschu"),
            Regel("ci", "tschi"), Regel("ce", "tsche"), Regel("gia", "dscha"), Regel("gio", "dscho"), Regel("giu", "dschu"), Regel("gi", "dschi"),
            Regel("ge", "dsche"), Regel("gli", "lji"), Regel("gn", "nj"), Regel("chi", "ki"), Regel("che", "ke"), Regel("sce", "sche"),
            Regel("sci", "schi"), Regel("zz", "z"), Regel("cc", "k"),
        ],
        .spanisch: [
            Regel("ch", "tsch"), Regel("h", ""), Regel("ll", "j"), Regel("ñ", "nj"), Regel("ão", "aung"), Regel("qu", "k"), Regel("j", "ch"),
            Regel("ce", "se"), Regel("ci", "si"), Regel("z", "s"), Regel("v", "b"), Regel("í", "i"), Regel("á", "a"), Regel("é", "e"),
            Regel("ó", "o"), Regel("ú", "u"),
        ],
        .englisch: [
            Regel("ough", "o"), Regel("igh", "ei"), Regel("mc", "mäk", .anfang), Regel("sh", "sch"), Regel("th", "s"), Regel("ee", "i"),
            Regel("oo", "u"), Regel("ea", "i"), Regel("wr", "r", .anfang), Regel("w", "u"), Regel("j", "dsch"), Regel("ay", "ei"), Regel("y", "i", .ende),
        ],
        .niederlaendisch: [
            Regel("ooij", "oi"), Regel("ij", "ei"), Regel("oe", "u"), Regel("ui", "eu"), Regel("uu", "ü"), Regel("aa", "a"),
            Regel("sch", "sch"), Regel("g", "ch"), Regel("v", "f"),
        ],
        .vietnamesisch: [
            Regel("nguy", "nui", .anfang), Regel("ng", "n", .anfang), Regel("ph", "f"), Regel("th", "t"), Regel("tr", "tsch"), Regel("đ", "d"),
            Regel("ư", "ü"), Regel("ơ", "ö"), Regel("x", "s"), Regel("uy", "ui"),
        ],
        .chinesisch: [
            Regel("zh", "dsch"), Regel("ch", "tsch"), Regel("sh", "sch"), Regel("x", "sch"), Regel("q", "tsch"), Regel("c", "z"),
            Regel("ao", "au"), Regel("ui", "uei"), Regel("ian", "jen"),
        ],
        .irisch: [
            Regel("siobh", "schiw"), Regel("bh", "w"), Regel("mh", "w"), Regel("ao", "i"), Regel("s", "sch", .anfang),
        ],
    ]

    public static func umschreiben(_ name: String, _ h: Herkunft) -> String {
        guard let r = regeln[h] else { return name }
        return ersetzeTeile(name) { wort in
            // Nur Wörter umschreiben, die selbst Merkmale dieser Sprache tragen ("Schmidt-Çelik" → nur "Çelik")
            let lower = wort.lowercased()
            guard merkmale.contains(where: { $0.herkunft == h && lower.range(of: $0.muster, options: .regularExpression) != nil }) else { return nil }
            let z = Array(wort.lowercased())
            var out = ""
            var i = 0
            while i < z.count {
                var treffer = false
                for regel in r {
                    let v = Array(regel.von)
                    guard i + v.count <= z.count, Array(z[i..<(i + v.count)]) == v else { continue }
                    if regel.ort == .anfang && i != 0 { continue }
                    if regel.ort == .ende && i + v.count != z.count { continue }
                    out += regel.nach
                    i += v.count
                    treffer = true
                    break
                }
                if !treffer {
                    out.append(z[i])
                    i += 1
                }
            }
            if out == wort.lowercased() { return wort }
            return out.prefix(1).uppercased() + out.dropFirst()
        }
    }

    /// Einfache Silbentrennung: Bindestrich vor Konsonant + Vokal.
    static func silbenTrennen(_ wort: String) -> String {
        let vokale = Set("aeiouäöüyAEIOUÄÖÜY")
        let z = Array(wort)
        var out = ""
        for i in z.indices {
            out.append(z[i])
            if i >= 1, i + 2 < z.count - 1, vokale.contains(z[i]), !vokale.contains(z[i + 1]), vokale.contains(z[i + 2]) {
                out.append("-")
            }
        }
        return out
    }

    /// Wendet eine Funktion auf jedes Teilwort an (getrennt durch Leerzeichen oder Bindestrich); nil = unverändert.
    static func ersetzeTeile(_ s: String, _ f: (String) -> String?) -> String {
        var out = ""
        var wort = ""
        func flush() {
            if !wort.isEmpty { out += f(wort) ?? wort }
            wort = ""
        }
        for c in s {
            if c == " " || c == "-" {
                flush()
                out.append(c)
            } else {
                wort.append(c)
            }
        }
        flush()
        return out
    }

    static func teilwoerter(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
    }
}
