import CommonCrypto
import Foundation
import Security
import WochenleichtCore

/// PBKDF2-SHA256 über Apples CommonCrypto.
struct PBKDF2Hasher: PasswordHasher {
    func hash(password: String, salt: Data, iterations: Int) -> Data {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived, derived.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 fehlgeschlagen: \(status)")
        return Data(derived)
    }

    func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Zufallszahlen nicht verfügbar")
        return Data(bytes)
    }
}
