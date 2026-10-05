import Foundation
import Observation
import WochenleichtCore

struct AuthUser: Codable, Hashable {
    let id: String
    let email: String
}

/// Registrierung und Anmeldung per E-Mail und Passwort – vollständig auf dem Gerät, ohne externen Server.
/// Konten liegen in einer dateigeschützten JSON-Datei; Passwörter werden mit PBKDF2-SHA256 gehasht.
@MainActor
@Observable
final class AuthService {
    enum State: Equatable {
        case signedOut
        case signedIn(AuthUser)
    }

    private static let sessionKey = "currentAccountId"

    private(set) var state: State = .signedOut
    @ObservationIgnored private var registry: AccountRegistry
    @ObservationIgnored private let hasher = PBKDF2Hasher()

    var currentUser: AuthUser? {
        if case let .signedIn(user) = state { return user }
        return nil
    }

    init() {
        registry = Self.loadRegistry()
        if let id = UserDefaults.standard.string(forKey: Self.sessionKey), let account = registry.account(id: id) {
            state = .signedIn(AuthUser(id: account.id, email: account.email))
        }
    }

    func register(email: String, password: String) async throws {
        let account = try await withRegistry { registry, hasher in
            try registry.register(email: email, password: password, hasher: hasher)
        }
        signIn(account)
    }

    func login(email: String, password: String) async throws {
        do {
            let account = try await withRegistry { registry, hasher in
                try registry.login(email: email, password: password, hasher: hasher)
            }
            signIn(account)
        } catch {
            saveRegistry() // Fehlversuche merken
            throw error
        }
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        state = .signedOut
    }

    func changePassword(current: String, new: String) async throws {
        guard let user = currentUser else { throw AccountError.notFound }
        _ = try await withRegistry { registry, hasher in
            try registry.changePassword(accountId: user.id, current: current, new: new, hasher: hasher)
        }
    }

    /// Löscht das Konto des angemeldeten Benutzers. Die App-Daten löscht der Aufrufer.
    func deleteAccount() {
        guard let user = currentUser else { return }
        registry.delete(accountId: user.id)
        saveRegistry()
        logout()
    }

    /// „Passwort vergessen“: Ohne Server gibt es keine Wiederherstellung per Mail – das Konto samt Daten wird zurückgesetzt.
    /// Gibt die ID des gelöschten Kontos zurück, damit dessen Daten entfernt werden können.
    func resetAccount(email: String) -> String? {
        guard let account = registry.account(email: email) else { return nil }
        registry.delete(accountId: account.id)
        saveRegistry()
        return account.id
    }

    private func signIn(_ account: LocalAccount) {
        UserDefaults.standard.set(account.id, forKey: Self.sessionKey)
        state = .signedIn(AuthUser(id: account.id, email: account.email))
    }

    /// Führt die rechenintensive Passwortprüfung abseits des Main Threads aus und speichert das Ergebnis.
    private func withRegistry<T: Sendable>(_ work: @escaping @Sendable (inout AccountRegistry, PBKDF2Hasher) throws -> T) async throws -> T {
        let snapshot = registry
        let hasher = hasher
        let (updated, result) = await Task.detached(priority: .userInitiated) { () -> (AccountRegistry, Result<T, Error>) in
            var copy = snapshot
            do {
                let value = try work(&copy, hasher)
                return (copy, .success(value))
            } catch {
                return (copy, .failure(error))
            }
        }.value
        registry = updated
        let value = try result.get()
        saveRegistry()
        return value
    }

    // MARK: Persistenz

    private static var registryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wochenleicht", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    private static func loadRegistry() -> AccountRegistry {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(AccountRegistry.self, from: data) else { return AccountRegistry() }
        return registry
    }

    private func saveRegistry() {
        do {
            let url = Self.registryURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(registry).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("[AuthService] Konten konnten nicht gespeichert werden: \(error)")
        }
    }
}
