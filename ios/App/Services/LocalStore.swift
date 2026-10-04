import Foundation
import WochenleichtCore

/// Speichert den App-Zustand pro Benutzer als JSON-Datei (Application Support, dateigeschützt).
struct LocalStore {
    let userId: String

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Wochenleicht", isDirectory: true)
    }

    private var dataURL: URL { directory.appendingPathComponent("appdata-\(safeId).json") }
    private var safeId: String { userId.filter { $0.isLetter || $0.isNumber || $0 == "-" } }

    func load() -> AppData? {
        guard let data = try? Data(contentsOf: dataURL) else { return nil }
        return try? AppData.decoder.decode(AppData.self, from: data)
    }

    func save(_ appData: AppData) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try AppData.encoder.encode(appData)
            try data.write(to: dataURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("[LocalStore] Speichern fehlgeschlagen: \(error)")
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: dataURL)
        UserDefaults.standard.removeObject(forKey: syncVersionKey)
    }

    // Server-Version des zuletzt synchronisierten Stands (für optimistische Nebenläufigkeit)
    private var syncVersionKey: String { "syncVersion-\(safeId)" }

    var syncVersion: Int {
        get { UserDefaults.standard.integer(forKey: syncVersionKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: syncVersionKey) }
    }
}
