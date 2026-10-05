import Foundation

/// Berechnet Passwort-Hashes. Die App nutzt PBKDF2-SHA256 (CommonCrypto); Tests können einen eigenen Hasher einsetzen.
public protocol PasswordHasher: Sendable {
    func hash(password: String, salt: Data, iterations: Int) -> Data
    func randomSalt() -> Data
}

public struct LocalAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var email: String
    public var salt: Data
    public var passwordHash: Data
    public var iterations: Int
    public let createdAt: Date
}

public enum AccountError: LocalizedError, Equatable {
    case invalidEmail
    case weakPassword(String)
    case emailTaken
    case invalidCredentials
    case lockedOut(seconds: Int)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalidEmail: "Bitte eine gültige E-Mail-Adresse angeben."
        case let .weakPassword(reason): reason
        case .emailTaken: "Für diese E-Mail-Adresse existiert auf diesem Gerät bereits ein Konto."
        case .invalidCredentials: "E-Mail oder Passwort ist falsch."
        case let .lockedOut(seconds): "Zu viele Fehlversuche. Bitte in \(seconds) Sekunden erneut versuchen."
        case .notFound: "Konto nicht gefunden."
        }
    }
}

public enum CredentialRules {
    public static let minimumPasswordLength = 8
    public static let maximumPasswordLength = 128

    public static func normalizeEmail(_ email: String) -> String? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard normalized.count <= 254, parts.count == 2, !parts[0].isEmpty,
              !normalized.contains(where: \.isWhitespace) else { return nil }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard domain.count >= 2, domain.allSatisfy({ !$0.isEmpty }), (domain.last?.count ?? 0) >= 2 else { return nil }
        return normalized
    }

    /// Fehlermeldung oder nil, wenn das Passwort den Regeln entspricht.
    public static func passwordProblem(_ password: String) -> String? {
        if password.count < minimumPasswordLength { return "Passwort muss mindestens \(minimumPasswordLength) Zeichen haben." }
        if password.count > maximumPasswordLength { return "Passwort darf höchstens \(maximumPasswordLength) Zeichen haben." }
        if !password.contains(where: \.isLetter) || !password.contains(where: \.isNumber) {
            return "Passwort muss mindestens einen Buchstaben und eine Ziffer enthalten."
        }
        return nil
    }
}

/// Auf dem Gerät gespeicherte Konten (ersetzt den externen Anmeldeserver).
public struct AccountRegistry: Codable, Hashable, Sendable {
    public static let defaultIterations = 210_000
    public static let maxFailedAttempts = 5
    public static let lockoutSeconds = 60

    struct FailedLogins: Codable, Hashable, Sendable {
        var count: Int
        var lockedUntil: Date?
    }

    public private(set) var accounts: [LocalAccount]
    var failedLogins: [String: FailedLogins]

    public init() {
        accounts = []
        failedLogins = [:]
    }

    public func account(id: String) -> LocalAccount? {
        accounts.first { $0.id == id }
    }

    public func account(email: String) -> LocalAccount? {
        guard let normalized = CredentialRules.normalizeEmail(email) else { return nil }
        return accounts.first { $0.email == normalized }
    }

    public mutating func register(email: String, password: String, hasher: PasswordHasher,
                                  iterations: Int = defaultIterations, now: Date = Date()) throws -> LocalAccount {
        guard let normalized = CredentialRules.normalizeEmail(email) else { throw AccountError.invalidEmail }
        if let problem = CredentialRules.passwordProblem(password) { throw AccountError.weakPassword(problem) }
        guard account(email: normalized) == nil else { throw AccountError.emailTaken }
        let salt = hasher.randomSalt()
        let account = LocalAccount(id: UUID().uuidString, email: normalized, salt: salt,
                                   passwordHash: hasher.hash(password: password, salt: salt, iterations: iterations),
                                   iterations: iterations, createdAt: now)
        accounts.append(account)
        return account
    }

    /// Prüft die Zugangsdaten. Nach mehreren Fehlversuchen wird das Konto kurz gesperrt.
    public mutating func login(email: String, password: String, hasher: PasswordHasher, now: Date = Date()) throws -> LocalAccount {
        let key = CredentialRules.normalizeEmail(email) ?? email.lowercased()
        if let lockedUntil = failedLogins[key]?.lockedUntil, lockedUntil > now {
            throw AccountError.lockedOut(seconds: Int(lockedUntil.timeIntervalSince(now).rounded(.up)))
        }
        guard let account = account(email: key),
              Self.constantTimeEquals(hasher.hash(password: password, salt: account.salt, iterations: account.iterations),
                                      account.passwordHash) else {
            var failed = failedLogins[key] ?? FailedLogins(count: 0)
            failed.count += 1
            if failed.count >= Self.maxFailedAttempts {
                failed.count = 0
                failed.lockedUntil = now.addingTimeInterval(TimeInterval(Self.lockoutSeconds))
            }
            failedLogins[key] = failed
            throw AccountError.invalidCredentials
        }
        failedLogins[key] = nil
        return account
    }

    public mutating func changePassword(accountId: String, current: String, new: String, hasher: PasswordHasher,
                                        iterations: Int = defaultIterations) throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { throw AccountError.notFound }
        let account = accounts[index]
        guard Self.constantTimeEquals(hasher.hash(password: current, salt: account.salt, iterations: account.iterations),
                                      account.passwordHash) else { throw AccountError.invalidCredentials }
        if let problem = CredentialRules.passwordProblem(new) { throw AccountError.weakPassword(problem) }
        let salt = hasher.randomSalt()
        accounts[index].salt = salt
        accounts[index].iterations = iterations
        accounts[index].passwordHash = hasher.hash(password: new, salt: salt, iterations: iterations)
    }

    public mutating func delete(accountId: String) {
        if let email = account(id: accountId)?.email { failedLogins[email] = nil }
        accounts.removeAll { $0.id == accountId }
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}
