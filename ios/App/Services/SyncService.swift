import Foundation
import WochenleichtCore

private struct RemoteData: Decodable {
    let version: Int
    let payload: AppData?
}

private struct PutBody: Encodable {
    let baseVersion: Int
    let payload: AppData
}

private struct PutResponse: Decodable {
    let version: Int
}

private struct ConflictBody: Decodable {
    struct Detail: Decodable {
        let current: RemoteData?
    }
    let error: Detail
}

/// Gleicht den lokalen Stand mit dem Server ab (iPhone ↔ iPad).
@MainActor
struct SyncService {
    let auth: AuthService
    let store: LocalStore

    /// Holt den Serverstand, führt ihn mit dem lokalen zusammen und lädt das Ergebnis hoch. Gibt den neuen Stand zurück.
    func synchronize(local: AppData) async throws -> AppData {
        let data = try await auth.authorizedData("GET", "v1/data")
        let remote = try AppData.decoder.decode(RemoteData.self, from: data)
        var merged = local
        if let payload = remote.payload {
            merged = local.merged(with: payload)
        }
        store.syncVersion = remote.version
        if remote.payload != merged {
            merged = try await push(merged, attempt: 0)
        }
        return merged
    }

    private func push(_ appData: AppData, attempt: Int) async throws -> AppData {
        let body = try AppData.encoder.encode(PutBody(baseVersion: store.syncVersion, payload: appData))
        do {
            let data = try await auth.authorizedData("PUT", "v1/data", body: body)
            store.syncVersion = try JSONDecoder().decode(PutResponse.self, from: data).version
            return appData
        } catch let APIError.server(status, _, _, responseBody) where status == 409 && attempt < 2 {
            // Ein anderes Gerät war schneller: zusammenführen und erneut versuchen.
            let conflict = try AppData.decoder.decode(ConflictBody.self, from: responseBody)
            guard let current = conflict.error.current else { throw APIError.invalidResponse }
            store.syncVersion = current.version
            let merged = current.payload.map { appData.merged(with: $0) } ?? appData
            return try await push(merged, attempt: attempt + 1)
        }
    }
}
