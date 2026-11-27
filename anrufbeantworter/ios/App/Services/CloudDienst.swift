import Foundation
import Security
import AnrufbeantworterCore

/// Zugangsschlüssel sicher im iOS-Schlüsselbund.
enum Schluesselbund {
    private static let dienst = "de.zollsoft.anrufbeantworter.cloud"

    static func lesen() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func speichern(_ token: String) {
        loeschen()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst,
                                kSecValueData as String: Data(token.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func loeschen() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst]
        SecItemDelete(q as CFDictionary)
    }
}

struct CloudIch: Decodable, Equatable {
    var id: String
    var name: String
    var cloudNummer: String
    var mobilnummer: String
    var stimme: String
    var telefonieBereit: Bool
    var transkription: Bool
    var letzteSynchronisierung: String?
}

struct CloudNachricht: Decodable, Identifiable, Equatable {
    struct Kontakt: Decodable, Equatable {
        var anrede: String?
        var titel: String?
        var vorname: String?
        var nachname: String?
        var organisation: String?
    }
    var id: String
    var zeit: String
    var nummer: String?
    var kontakt: Kontakt?
    var status: String
    var prioritaet: String
    var dauerSekunden: Int
    var transkript: String
    var ohneNachricht: Bool?
    var erledigt: Bool
    var hatAufnahme: Bool

    var anrufer: String {
        if let k = kontakt {
            let name = [k.anrede, k.titel, k.vorname, k.nachname].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { return name }
            if let o = k.organisation, !o.isEmpty { return o }
        }
        return nummer ?? "Rufnummer unterdrückt"
    }

    var datum: Date? { ISO8601DateFormatter.mitMillisekunden.date(from: zeit) ?? ISO8601DateFormatter().date(from: zeit) }
}

extension ISO8601DateFormatter {
    static let mitMillisekunden: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Verbindung zum Cloud-Anrufbeantworter: Einstellungen übertragen, Nachrichten abrufen, Probeanruf.
@MainActor
@Observable
final class CloudDienst {
    enum Fehler: LocalizedError {
        case keinZugang, server(String), ungueltigeAdresse
        var errorDescription: String? {
            switch self {
            case .keinZugang: "Kein Zugangsschlüssel hinterlegt."
            case .server(let m): m
            case .ungueltigeAdresse: "Die Server-Adresse ist ungültig."
            }
        }
    }

    private(set) var ich: CloudIch?
    private(set) var letzteUebertragung: Date?
    private(set) var syncFehler: String?
    private(set) var nachrichten: [CloudNachricht] = []

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var letzterInhalt: Data?

    var hatZugang: Bool { Schluesselbund.lesen() != nil }

    // MARK: Verbindung

    func verbinden(server: String, token: String) async throws -> CloudIch {
        Schluesselbund.speichern(token.trimmingCharacters(in: .whitespacesAndNewlines))
        let ich: CloudIch = try await anfrage("GET", "/api/app/ich", server: server)
        self.ich = ich
        return ich
    }

    func trennen() {
        Schluesselbund.loeschen()
        ich = nil
        nachrichten = []
        letzterInhalt = nil
    }

    func aktualisieren(_ k: AppKonfiguration) async {
        guard let server = k.cloud?.serverURL else { return }
        ich = try? await anfrage("GET", "/api/app/ich", server: server)
    }

    // MARK: Übertragung (verzögert, damit nicht jeder Tastendruck gesendet wird)

    func planeUebertragung(_ k: AppKonfiguration) {
        guard k.cloudAktiv, hatZugang else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await uebertragen(k)
        }
    }

    func uebertragen(_ k: AppKonfiguration, erzwingen: Bool = false) async {
        guard let server = k.cloud?.serverURL else { return }
        do {
            let daten = try CloudPayload(k).json()
            if !erzwingen, daten == letzterInhalt { return }
            struct Antwort: Decodable { var ok: Bool }
            let _: Antwort = try await anfrage("PUT", "/api/app/konfiguration", server: server, body: daten)
            letzterInhalt = daten
            letzteUebertragung = Date()
            syncFehler = nil
        } catch {
            syncFehler = error.localizedDescription
        }
    }

    // MARK: Nachrichten

    func ladeNachrichten(_ k: AppKonfiguration) async throws {
        guard let server = k.cloud?.serverURL else { return }
        nachrichten = try await anfrage("GET", "/api/app/nachrichten", server: server)
    }

    func setzeErledigt(_ n: CloudNachricht, _ erledigt: Bool, _ k: AppKonfiguration) async throws {
        guard let server = k.cloud?.serverURL else { return }
        struct Antwort: Decodable { var ok: Bool }
        let body = try JSONEncoder().encode(["erledigt": erledigt])
        let _: Antwort = try await anfrage("PATCH", "/api/app/nachrichten/\(n.id)", server: server, body: body)
        if let i = nachrichten.firstIndex(where: { $0.id == n.id }) { nachrichten[i].erledigt = erledigt }
    }

    func ladeAufnahme(_ n: CloudNachricht, _ k: AppKonfiguration) async throws -> Data {
        guard let server = k.cloud?.serverURL else { throw Fehler.ungueltigeAdresse }
        return try await rohAnfrage("GET", "/api/app/nachrichten/\(n.id)/audio", server: server).0
    }

    // MARK: Test

    struct Vorschau: Decodable { var text: String; var ssml: String }

    func vorschau(_ k: AppKonfiguration, alsAnrufer: String? = nil) async throws -> Vorschau {
        guard let server = k.cloud?.serverURL else { throw Fehler.ungueltigeAdresse }
        var pfad = "/api/app/vorschau"
        if let a = alsAnrufer, let q = a.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { pfad += "?from=\(q)" }
        return try await anfrage("GET", pfad, server: server)
    }

    func probeanruf(_ k: AppKonfiguration) async throws {
        guard let server = k.cloud?.serverURL else { throw Fehler.ungueltigeAdresse }
        await uebertragen(k, erzwingen: true)
        struct Antwort: Decodable { var sid: String? }
        let _: Antwort = try await anfrage("POST", "/api/app/probeanruf", server: server, body: Data("{}".utf8))
    }

    // MARK: HTTP

    private func anfrage<T: Decodable>(_ methode: String, _ pfad: String, server: String, body: Data? = nil) async throws -> T {
        let (data, _) = try await rohAnfrage(methode, pfad, server: server, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rohAnfrage(_ methode: String, _ pfad: String, server: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token = Schluesselbund.lesen() else { throw Fehler.keinZugang }
        let basis = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: basis + pfad), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw Fehler.ungueltigeAdresse
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = methode
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Fehler.server("Keine Antwort vom Server") }
        guard (200..<300).contains(http.statusCode) else {
            struct F: Decodable { var fehler: String }
            let meldung = (try? JSONDecoder().decode(F.self, from: data).fehler) ?? "HTTP \(http.statusCode)"
            throw Fehler.server(meldung)
        }
        return (data, http)
    }
}
