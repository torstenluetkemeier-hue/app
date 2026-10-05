import XCTest
@testable import WochenleichtCore

/// Schneller, deterministischer Test-Hasher (die App verwendet PBKDF2-SHA256).
struct TestHasher: PasswordHasher {
    func hash(password: String, salt: Data, iterations: Int) -> Data {
        var bytes = Array(salt) + Array(password.utf8)
        for i in bytes.indices { bytes[i] = bytes[i] &+ UInt8(truncatingIfNeeded: iterations &+ i) }
        return Data(bytes)
    }

    func randomSalt() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }
}

final class AccountTests: XCTestCase {
    let hasher = TestHasher()

    func testRegisterNormalizesEmailAndRejectsDuplicates() throws {
        var registry = AccountRegistry()
        let account = try registry.register(email: "  Anna@Example.DE ", password: "geheim123", hasher: hasher)
        XCTAssertEqual(account.email, "anna@example.de")
        XCTAssertNotEqual(account.passwordHash, Data("geheim123".utf8), "Passwort wird nicht im Klartext gespeichert")
        XCTAssertThrowsError(try registry.register(email: "anna@example.de", password: "geheim123", hasher: hasher)) {
            XCTAssertEqual($0 as? AccountError, .emailTaken)
        }
    }

    func testValidation() {
        var registry = AccountRegistry()
        for email in ["kein-mail", "a@b", "a b@c.de", "@example.de", "a@example."] {
            XCTAssertThrowsError(try registry.register(email: email, password: "geheim123", hasher: hasher), email) {
                XCTAssertEqual($0 as? AccountError, .invalidEmail)
            }
        }
        for password in ["kurz1", "nurbuchstaben", "12345678"] {
            XCTAssertThrowsError(try registry.register(email: "b@example.de", password: password, hasher: hasher), password)
        }
    }

    func testLoginAndLockout() throws {
        var registry = AccountRegistry()
        let account = try registry.register(email: "anna@example.de", password: "geheim123", hasher: hasher)
        XCTAssertEqual(try registry.login(email: "ANNA@example.de", password: "geheim123", hasher: hasher).id, account.id)
        XCTAssertThrowsError(try registry.login(email: "niemand@example.de", password: "geheim123", hasher: hasher)) {
            XCTAssertEqual($0 as? AccountError, .invalidCredentials)
        }

        let now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<AccountRegistry.maxFailedAttempts {
            XCTAssertThrowsError(try registry.login(email: "anna@example.de", password: "falsch123", hasher: hasher, now: now))
        }
        // Gesperrt – selbst das richtige Passwort wird abgewiesen
        XCTAssertThrowsError(try registry.login(email: "anna@example.de", password: "geheim123", hasher: hasher, now: now)) {
            XCTAssertEqual($0 as? AccountError, .lockedOut(seconds: AccountRegistry.lockoutSeconds))
        }
        let later = now.addingTimeInterval(TimeInterval(AccountRegistry.lockoutSeconds + 1))
        XCTAssertNoThrow(try registry.login(email: "anna@example.de", password: "geheim123", hasher: hasher, now: later))
    }

    func testChangePasswordAndDelete() throws {
        var registry = AccountRegistry()
        let account = try registry.register(email: "anna@example.de", password: "geheim123", hasher: hasher)
        XCTAssertThrowsError(try registry.changePassword(accountId: account.id, current: "falsch123", new: "neuesPw99", hasher: hasher))
        try registry.changePassword(accountId: account.id, current: "geheim123", new: "neuesPw99", hasher: hasher)
        XCTAssertThrowsError(try registry.login(email: "anna@example.de", password: "geheim123", hasher: hasher))
        XCTAssertNoThrow(try registry.login(email: "anna@example.de", password: "neuesPw99", hasher: hasher))

        registry.delete(accountId: account.id)
        XCTAssertNil(registry.account(id: account.id))
        XCTAssertNoThrow(try registry.register(email: "anna@example.de", password: "geheim123", hasher: hasher), "E-Mail wieder frei")
    }

    func testRegistryRoundTrip() throws {
        var registry = AccountRegistry()
        _ = try registry.register(email: "anna@example.de", password: "geheim123", hasher: hasher)
        let decoded = try JSONDecoder().decode(AccountRegistry.self, from: JSONEncoder().encode(registry))
        XCTAssertEqual(decoded, registry)
    }
}
