import Foundation
import Observation

struct AuthUser: Codable, Hashable {
    let id: String
    let email: String
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: AuthUser
}

private struct Credentials: Encodable {
    let email: String
    let password: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
}

private struct PasswordChange: Encodable {
    let currentPassword: String
    let newPassword: String
}

/// Anmeldung per E-Mail und Passwort gegen den eigenen Server.
@MainActor
@Observable
final class AuthService {
    enum State: Equatable {
        case signedOut
        case signedIn(AuthUser)
    }

    private static let refreshKey = "refreshToken"
    private static let userKey = "currentUser"

    private(set) var state: State = .signedOut
    let api: APIClient

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?

    var currentUser: AuthUser? {
        if case let .signedIn(user) = state { return user }
        return nil
    }

    init(api: APIClient) {
        self.api = api
        // Offline-fähig: Ist ein Refresh-Token vorhanden, gilt der Nutzer als angemeldet.
        if KeychainStore.get(Self.refreshKey) != nil,
           let data = UserDefaults.standard.data(forKey: Self.userKey),
           let user = try? JSONDecoder().decode(AuthUser.self, from: data) {
            state = .signedIn(user)
        }
    }

    func register(email: String, password: String) async throws {
        let response: TokenResponse = try await api.send("POST", "v1/auth/register", body: Credentials(email: email, password: password))
        apply(response)
    }

    func login(email: String, password: String) async throws {
        let response: TokenResponse = try await api.send("POST", "v1/auth/login", body: Credentials(email: email, password: password))
        apply(response)
    }

    func logout() async {
        if let refresh = KeychainStore.get(Self.refreshKey) {
            let body = try? JSONEncoder().encode(RefreshBody(refreshToken: refresh))
            _ = try? await api.data("POST", "v1/auth/logout", body: body)
        }
        clearSession()
    }

    func changePassword(current: String, new: String) async throws {
        let token = try await validAccessToken()
        let response: TokenResponse = try await api.send("PUT", "v1/me/password",
                                                         body: PasswordChange(currentPassword: current, newPassword: new), token: token)
        apply(response)
    }

    /// Löscht das Konto inkl. aller Serverdaten (App-Store-Pflicht).
    func deleteAccount() async throws {
        _ = try await authorizedData("DELETE", "v1/me")
        clearSession()
    }

    /// Führt eine authentifizierte Anfrage aus und erneuert das Token bei Bedarf einmalig.
    func authorizedData(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let token = try await validAccessToken()
        do {
            return try await api.data(method, path, body: body, token: token)
        } catch let error as APIError where error.status == 401 {
            accessToken = nil
            let fresh = try await validAccessToken()
            return try await api.data(method, path, body: body, token: fresh)
        }
    }

    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(30) {
            return accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<String, Error> { [api] in
            guard let refresh = KeychainStore.get(Self.refreshKey) else {
                throw APIError.server(status: 401, code: "unauthorized", message: "Bitte erneut anmelden.", body: Data())
            }
            let response: TokenResponse = try await api.send("POST", "v1/auth/refresh", body: RefreshBody(refreshToken: refresh))
            self.apply(response)
            return response.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch let error as APIError where error.status == 401 {
            clearSession()
            throw error
        }
    }

    private func apply(_ response: TokenResponse) {
        accessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        KeychainStore.set(response.refreshToken, for: Self.refreshKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(response.user), forKey: Self.userKey)
        state = .signedIn(response.user)
    }

    private func clearSession() {
        accessToken = nil
        accessTokenExpiry = .distantPast
        KeychainStore.set(nil, for: Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        state = .signedOut
    }
}
