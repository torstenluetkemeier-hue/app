import Foundation

/// Grund, warum gerade niemand abnimmt.
public enum Modus: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, termin, abwesend, urlaub, krank

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: "Nicht erreichbar"
        case .termin: "Im Termin"
        case .abwesend: "Unterwegs"
        case .urlaub: "Urlaub"
        case .krank: "Krank"
        }
    }

    public var symbol: String {
        switch self {
        case .standard: "phone.down"
        case .termin: "person.2.wave.2"
        case .abwesend: "car"
        case .urlaub: "sun.max"
        case .krank: "cross.case"
        }
    }

    /// Ganztägige Abwesenheiten werden mit Datum, Termine mit Uhrzeit angegeben.
    public var istGanztaegig: Bool { self == .urlaub || self == .krank || self == .abwesend }
}

public enum TerminArt: String, Codable, CaseIterable, Identifiable, Sendable {
    case onlinePraesentation, praesentationVorOrt, schulung, webinar, kundentermin, installation, besprechung, telefonat, sonstiges

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .onlinePraesentation: "Online-Präsentation"
        case .praesentationVorOrt: "Präsentation vor Ort"
        case .schulung: "Schulung"
        case .webinar: "Online-Schulung / Webinar"
        case .kundentermin: "Kundentermin"
        case .installation: "Installation in einer Praxis"
        case .besprechung: "Besprechung"
        case .telefonat: "Anderes Gespräch"
        case .sonstiges: "Sonstiges (Freitext)"
        }
    }

    public var ansage: String {
        switch self {
        case .onlinePraesentation: "in einer Online-Präsentation"
        case .praesentationVorOrt: "bei einer Präsentation vor Ort"
        case .schulung: "in einer Schulung"
        case .webinar: "in einem Webinar"
        case .kundentermin: "bei einem Kundentermin"
        case .installation: "bei einer Installation in einer Praxis"
        case .besprechung: "in einer Besprechung"
        case .telefonat: "in einem anderen Gespräch"
        case .sonstiges: "in einem Termin"
        }
    }
}

public enum AbwesendArt: String, Codable, CaseIterable, Identifiable, Sendable {
    case dienstreise, messe, fortbildung, sonstiges

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dienstreise: "Dienstreise"
        case .messe: "Messe / Kongress"
        case .fortbildung: "Fortbildung"
        case .sonstiges: "Sonstiges (Freitext)"
        }
    }

    public var ansage: String {
        switch self {
        case .dienstreise: "auf Dienstreise"
        case .messe: "auf einer Messe"
        case .fortbildung: "auf einer Fortbildung"
        case .sonstiges: "unterwegs"
        }
    }
}

public struct Vertretung: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var telefon: String

    public init(id: UUID = UUID(), name: String, telefon: String) {
        self.id = id
        self.name = name
        self.telefon = telefon
    }
}

/// Welche Vertretung in der Ansage genannt wird.
public enum VertretungsWahl: Codable, Hashable, Sendable {
    /// Standard-Vertretung, falls für den Modus vorgesehen
    case automatisch
    case keine
    case person(UUID)
}

/// Ein Status, entweder sofort gesetzt oder als Kalendereintrag geplant.
public struct Status: Codable, Equatable, Sendable {
    public var modus: Modus
    public var terminArt: TerminArt
    public var abwesendArt: AbwesendArt
    public var freitext: String
    /// Ende; bei ganztägigen Modi zählt der ganze Tag.
    public var bis: Date?
    public var vertretung: VertretungsWahl

    public init(modus: Modus, terminArt: TerminArt = .onlinePraesentation, abwesendArt: AbwesendArt = .dienstreise,
                freitext: String = "", bis: Date? = nil, vertretung: VertretungsWahl = .automatisch) {
        self.modus = modus
        self.terminArt = terminArt
        self.abwesendArt = abwesendArt
        self.freitext = freitext
        self.bis = bis
        self.vertretung = vertretung
    }
}

public struct KalenderEintrag: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var titel: String
    public var von: Date
    public var status: Status

    public init(id: UUID = UUID(), titel: String = "", von: Date, status: Status) {
        self.id = id
        self.titel = titel
        self.von = von
        self.status = status
    }
}

public struct Profil: Codable, Equatable, Sendable {
    public var vorname: String
    public var nachname: String
    public var funktion: String
    public var firma: String
    public var produkt: String

    public init(vorname: String = "", nachname: String = "", funktion: String = "", firma: String = "zollsoft", produkt: String = "tomedo") {
        self.vorname = vorname
        self.nachname = nachname
        self.funktion = funktion
        self.firma = firma
        self.produkt = produkt
    }

    public var name: String { [vorname, nachname].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Stimme und Sprechweise. Für eine einheitliche Wirkung gibt es einen Firmenstandard.
public struct StimmenEinstellung: Codable, Equatable, Sendable {
    /// Kennung der iOS-Stimme (`AVSpeechSynthesisVoice.identifier`), nil = beste verfügbare deutsche Stimme
    public var stimmeID: String?
    /// 0…1 wie `AVSpeechUtterance.rate` (0,5 = normal)
    public var tempo: Float
    /// 0,5…2,0
    public var tonhoehe: Float
    /// Pause zwischen den Abschnitten der Ansage in Millisekunden
    public var pauseMs: Int

    public static let firmenStandard = StimmenEinstellung(stimmeID: nil, tempo: 0.48, tonhoehe: 1.0, pauseMs: 450)

    public init(stimmeID: String?, tempo: Float, tonhoehe: Float, pauseMs: Int) {
        self.stimmeID = stimmeID
        self.tempo = tempo
        self.tonhoehe = tonhoehe
        self.pauseMs = pauseMs
    }
}

public struct AppKonfiguration: Codable, Equatable, Sendable {
    public var profil: Profil
    public var vertretungen: [Vertretung]
    public var standardVertretungID: UUID?
    /// In diesen Modi wird die Standard-Vertretung automatisch genannt.
    public var vertretungNennenIn: Set<Modus>
    /// Sofort gesetzter Status; nil = Standardansage bzw. Kalender
    public var status: Status?
    public var kalender: [KalenderEintrag]
    public var texte: AnsageTexte
    public var stimme: StimmenEinstellung
    public var lexikon: [AusspracheEintrag]
    /// Zusätzliche Namen, die geprüft werden sollen (z. B. wichtige Kunden)
    public var testnamen: [String]
    /// Bei neuen oder geänderten Namen anbieten, die Aussprache zu prüfen (kein Zwang)
    public var nachAusspracheFragen: Bool
    public var onboardingErledigt: Bool

    public init(profil: Profil = Profil(), vertretungen: [Vertretung] = [], standardVertretungID: UUID? = nil,
                vertretungNennenIn: Set<Modus> = [.urlaub, .krank, .abwesend], status: Status? = nil,
                kalender: [KalenderEintrag] = [], texte: AnsageTexte = .firmenStandard,
                stimme: StimmenEinstellung = .firmenStandard, lexikon: [AusspracheEintrag] = [],
                testnamen: [String] = [], nachAusspracheFragen: Bool = true, onboardingErledigt: Bool = false) {
        self.profil = profil
        self.vertretungen = vertretungen
        self.standardVertretungID = standardVertretungID
        self.vertretungNennenIn = vertretungNennenIn
        self.status = status
        self.kalender = kalender
        self.texte = texte
        self.stimme = stimme
        self.lexikon = lexikon
        self.testnamen = testnamen
        self.nachAusspracheFragen = nachAusspracheFragen
        self.onboardingErledigt = onboardingErledigt
    }

    public static let beispiel: AppKonfiguration = {
        let thomas = Vertretung(name: "Thomas Müller", telefon: "+49 3641 000 200")
        return AppKonfiguration(
            profil: Profil(vorname: "Max", nachname: "Meyer", funktion: "Kundenberater"),
            vertretungen: [thomas],
            standardVertretungID: thomas.id
        )
    }()
}
