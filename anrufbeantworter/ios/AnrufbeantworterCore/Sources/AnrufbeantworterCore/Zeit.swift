import Foundation

/// Gesprochene Datums- und Uhrzeitangaben, immer in deutscher Ortszeit.
public enum Zeit {
    public static let zeitzone = TimeZone(identifier: "Europe/Berlin")!

    public static var kalender: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zeitzone
        return c
    }

    private static let wochentage = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
    private static let monate = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    /// "Freitag, 4. Dezember"
    public static func gesprochenesDatum(_ d: Date) -> String {
        let c = kalender.dateComponents([.weekday, .day, .month], from: d)
        return "\(wochentage[c.weekday! - 1]), \(c.day!). \(monate[c.month! - 1])"
    }

    /// "15 Uhr", "15 Uhr 30"
    public static func gesprocheneUhrzeit(_ d: Date) -> String {
        let c = kalender.dateComponents([.hour, .minute], from: d)
        return c.minute! == 0 ? "\(c.hour!) Uhr" : "\(c.hour!) Uhr \(c.minute!)"
    }

    /// Ende einer Abwesenheit für die Ansage.
    public static func bisText(_ bis: Date?, ganztags: Bool, jetzt: Date) -> String {
        guard let bis else { return "" }
        if ganztags { return "bis einschließlich \(gesprochenesDatum(bis))" }
        if kalender.isDate(bis, inSameDayAs: jetzt) { return "voraussichtlich bis \(gesprocheneUhrzeit(bis))" }
        return "voraussichtlich bis \(gesprochenesDatum(bis)), \(gesprocheneUhrzeit(bis))"
    }

    /// Ende eines Status als Zeitpunkt: Bei ganztägigen Modi zählt der ganze Tag.
    public static func effektivesEnde(_ status: Status) -> Date? {
        guard let bis = status.bis else { return nil }
        guard status.modus.istGanztaegig else { return bis }
        let start = kalender.startOfDay(for: bis)
        return kalender.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
    }

    /// Beginn eines Kalendereintrags: bei ganztägigen Modi Tagesbeginn.
    public static func effektiverBeginn(_ e: KalenderEintrag) -> Date {
        e.status.modus.istGanztaegig ? kalender.startOfDay(for: e.von) : e.von
    }
}
