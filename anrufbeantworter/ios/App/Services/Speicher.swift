import Foundation
import UserNotifications
import AnrufbeantworterCore

/// Konfiguration als JSON im App-Container (nur auf dem Gerät).
struct Speicher {
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("konfiguration.json")
    }()

    func laden() -> AppKonfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppKonfiguration.self, from: data)
    }

    func speichern(_ k: AppKonfiguration) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(k) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}

/// Erinnerungen: Die Mailbox-Ansage wechselt nicht von selbst. Deshalb erinnert die App,
/// wenn ein Status abläuft oder ein geplanter Eintrag beginnt bzw. endet.
enum Erinnerungen {
    static func erlaubnisAnfragen() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func planen(_ k: AppKonfiguration, jetzt: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        var termine: [(Date, String, String)] = []
        if let s = k.status, let ende = Zeit.effektivesEnde(s), ende > jetzt {
            termine.append((ende.addingTimeInterval(1), "„\(s.modus.label)“ ist vorbei", "Bitte die Standardansage wieder aktivieren."))
        }
        for e in k.kalender {
            let beginn = Zeit.effektiverBeginn(e)
            let titel = e.titel.isEmpty ? e.status.modus.label : e.titel
            if beginn > jetzt {
                termine.append((beginn, "Jetzt: \(titel)", "Ansage für „\(e.status.modus.label)“ aktivieren."))
            }
            if let ende = Zeit.effektivesEnde(e.status), ende > jetzt {
                termine.append((ende.addingTimeInterval(1), "\(titel) ist vorbei", "Bitte die Standardansage wieder aktivieren."))
            }
        }
        // iOS erlaubt höchstens 64 geplante Mitteilungen
        for (i, t) in termine.sorted(by: { $0.0 < $1.0 }).prefix(60).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = t.1
            content.body = t.2
            content.sound = .default
            let comps = Zeit.kalender.dateComponents([.year, .month, .day, .hour, .minute], from: t.0)
            let req = UNNotificationRequest(identifier: "ansage-\(i)", content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            center.add(req)
        }
    }
}
