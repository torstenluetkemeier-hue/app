import Foundation

/// Einstellungen für den Cloud-Anrufbeantworter. Der Zugangsschlüssel liegt im Schlüsselbund, nicht hier.
public struct CloudEinstellung: Codable, Equatable, Sendable {
    public var aktiv: Bool
    public var serverURL: String
    /// Eigene Handynummer (von ihr wird umgeleitet; dient dem Server zur Zuordnung und für Probeanrufe)
    public var mobilnummer: String
    /// Nach wie vielen Sekunden Klingeln umgeleitet wird (5–30)
    public var klingelSekunden: Int

    public init(aktiv: Bool = false, serverURL: String = "", mobilnummer: String = "", klingelSekunden: Int = 20) {
        self.aktiv = aktiv
        self.serverURL = serverURL
        self.mobilnummer = mobilnummer
        self.klingelSekunden = klingelSekunden
    }
}

// MARK: - Rufumleitung (GSM-Codes, gelten bei allen deutschen Netzbetreibern)

public enum Rufumleitung {
    public struct Code: Identifiable, Equatable, Sendable {
        public var id: String { code }
        public var titel: String
        public var code: String
        public var erklaerung: String
    }

    /// Zielnummer international ohne Leerzeichen: "+49 30 111222" → "+4930111222", "030 111222" → "+4930111222"
    public static func zielnummer(_ roh: String) -> String {
        let s = roh.replacingOccurrences(of: "(0)", with: "")
        var z = s.filter { $0.isNumber || $0 == "+" }
        if z.hasPrefix("00") { z = "+" + z.dropFirst(2) }
        else if z.hasPrefix("0") { z = "+49" + z.dropFirst() }
        return z
    }

    /// Klingeldauer: 5–30 Sekunden in 5er-Schritten (so verlangen es die Netze)
    public static func klingeldauer(_ s: Int) -> Int {
        min(30, max(5, Int((Double(s) / 5).rounded()) * 5))
    }

    public static func einrichten(nummer: String, sekunden: Int) -> [Code] {
        let n = zielnummer(nummer)
        return [
            Code(titel: "Bei Nichtannahme", code: "**61*\(n)*11*\(klingeldauer(sekunden))#",
                 erklaerung: "Nach \(klingeldauer(sekunden)) Sekunden Klingeln übernimmt der Cloud-Anrufbeantworter."),
            Code(titel: "Bei besetzt", code: "**67*\(n)#", erklaerung: "Wenn du gerade telefonierst oder ablehnst."),
            Code(titel: "Bei nicht erreichbar", code: "**62*\(n)#", erklaerung: "Handy aus oder kein Netz."),
        ]
    }

    public static let pruefen = Code(titel: "Umleitung prüfen", code: "*#61#", erklaerung: "Zeigt, wohin bei Nichtannahme umgeleitet wird.")

    public static let aufheben: [Code] = [
        Code(titel: "Alle bedingten Umleitungen löschen", code: "##004#",
             erklaerung: "Danach ggf. die Mailbox des Netzbetreibers wieder einrichten."),
    ]
}

// MARK: - Übertragung an den Server (Format von PUT /api/app/konfiguration)

public struct CloudPayload: Encodable, Equatable, Sendable {
    public struct Profil: Encodable, Equatable, Sendable { var vorname, nachname, funktion: String }
    public struct Firma: Encodable, Equatable, Sendable { var name, produkt: String }
    public struct Vertretung: Encodable, Equatable, Sendable { var id, name, telefon: String }
    public struct StatusDTO: Encodable, Equatable, Sendable {
        var modus, art, freitext, bis: String
        var ganztags: Bool
        var vertretungId: String?
    }
    public struct Eintrag: Encodable, Equatable, Sendable {
        var id, titel, modus, art, freitext, von, bis: String
        var ganztags: Bool
        var vertretungId: String?
    }
    public struct Texte: Encodable, Equatable, Sendable {
        var intro, vertretung, abschluss: String
        var modi: [String: String]
    }
    public struct Lexikon: Encodable, Equatable, Sendable { var schreibweise, lautschrift, ipa: String }
    public struct Stimme: Encodable, Equatable, Sendable { var tempo: Float; var pauseMs: Int }
    public struct Cloud: Encodable, Equatable, Sendable { var mobilnummer: String }

    public var version: String
    public var profil: Profil
    public var firma: Firma
    public var vertretungen: [Vertretung]
    public var standardVertretungId: String
    public var vertretungNennenIn: [String]
    public var status: StatusDTO?
    public var kalender: [Eintrag]
    public var texte: Texte
    public var lexikon: [Lexikon]
    public var stimme: Stimme
    public var cloud: Cloud

    public init(_ k: AppKonfiguration, version: String = "0.3.0") {
        self.version = version
        profil = Profil(vorname: k.profil.vorname, nachname: k.profil.nachname, funktion: k.profil.funktion)
        firma = Firma(name: k.profil.firma, produkt: k.profil.produkt)
        vertretungen = k.vertretungen.map { Vertretung(id: $0.id.uuidString, name: $0.name, telefon: $0.telefon) }
        standardVertretungId = k.standardVertretungID?.uuidString ?? ""
        vertretungNennenIn = k.vertretungNennenIn.map(\.rawValue).sorted()
        status = k.status.map(Self.status)
        kalender = k.kalender.map(Self.eintrag)
        texte = Texte(
            intro: Self.serverVorlage(k.texte.intro, intro: true),
            vertretung: Self.serverVorlage(k.texte.vertretung),
            abschluss: Self.serverVorlage(k.texte.abschluss),
            modi: Dictionary(uniqueKeysWithValues: Modus.allCases.map { ($0.rawValue, Self.serverVorlage(k.texte.text(fuer: $0))) })
        )
        lexikon = k.lexikon.filter(\.hatKorrektur).map { Lexikon(schreibweise: $0.schreibweise, lautschrift: $0.lautschrift, ipa: $0.ipa) }
        stimme = Stimme(tempo: k.stimme.tempo, pauseMs: k.stimme.pauseMs)
        cloud = Cloud(mobilnummer: k.cloud?.mobilnummer ?? "")
    }

    /// App-Platzhalter → Server-Platzhalter. In der Cloud wird der erkannte Anrufer begrüßt:
    /// ein einleitendes "Guten Tag!" wird deshalb zu "{{begruessung}}!" ("Guten Tag, Frau Dr. Schneider!").
    public static func serverVorlage(_ s: String, intro: Bool = false) -> String {
        let zuordnung = [
            "vertretungTelefon": "vertretung.telefonAnsage", "vertretung": "vertretung.name",
            "name": "ich.name", "vorname": "ich.vorname", "funktion": "ich.funktion",
            "firma": "firma.name", "produkt": "firma.produkt",
        ]
        var out = s
        for (app, server) in zuordnung {
            for prefix in ["{{", "{{#", "{{^", "{{/"] {
                out = out.replacingOccurrences(of: "\(prefix)\(app)}}", with: "\(prefix)\(server)}}")
            }
        }
        if intro {
            for gruss in ["Guten Tag!", "Guten Tag,", "Hallo!"] where out.hasPrefix(gruss) {
                out = "{{begruessung}}" + String(gruss.last!) + out.dropFirst(gruss.count)
                break
            }
        }
        return out
    }

    static func stempel(_ d: Date, nurDatum: Bool) -> String {
        let c = Zeit.kalender.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let datum = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return nurDatum ? datum : datum + String(format: "T%02d:%02d", c.hour!, c.minute!)
    }

    static func art(_ s: Status) -> String {
        switch s.modus {
        case .termin:
            switch s.terminArt {
            case .onlinePraesentation: return "online-praesentation"
            case .praesentationVorOrt: return "praesentation-vor-ort"
            case .besprechung: return "meeting"
            default: return s.terminArt.rawValue
            }
        case .abwesend: return s.abwesendArt.rawValue
        default: return ""
        }
    }

    static func vertretungId(_ w: VertretungsWahl) -> String? {
        switch w {
        case .automatisch: nil
        case .keine: ""
        case .person(let id): id.uuidString
        }
    }

    static func status(_ s: Status) -> StatusDTO {
        StatusDTO(modus: s.modus.rawValue, art: art(s), freitext: s.freitext,
                  bis: s.bis.map { stempel($0, nurDatum: s.modus.istGanztaegig) } ?? "",
                  ganztags: s.modus.istGanztaegig, vertretungId: vertretungId(s.vertretung))
    }

    static func eintrag(_ e: KalenderEintrag) -> Eintrag {
        let ganz = e.status.modus.istGanztaegig
        let von = stempel(e.von, nurDatum: ganz)
        // Ohne Ende: ganztägig nur dieser Tag, Termin bis Tagesende
        let bis = e.status.bis.map { stempel($0, nurDatum: ganz) } ?? (ganz ? von : stempel(e.von, nurDatum: true) + "T23:59")
        return Eintrag(id: e.id.uuidString, titel: e.titel, modus: e.status.modus.rawValue, art: art(e.status),
                       freitext: e.status.freitext, von: von, bis: max(bis, von), ganztags: ganz,
                       vertretungId: vertretungId(e.status.vertretung))
    }

    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}
