import Foundation

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }
    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public init(minutesSinceMidnight: Int) {
        let clamped = min(max(minutesSinceMidnight, 0), 23 * 60 + 59)
        self.init(hour: clamped / 60, minute: clamped % 60)
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.minutesSinceMidnight < rhs.minutesSinceMidnight }
}

public struct WaterEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var milliliters: Int

    public init(id: UUID = UUID(), date: Date, milliliters: Int) {
        self.id = id
        self.date = date
        self.milliliters = milliliters
    }
}

public struct WaterLog: Codable, Hashable, Sendable {
    public static let minimumDailyGoalMl = 3000

    public private(set) var entries: [WaterEntry]
    /// Gelöschte Einträge – nötig, damit Löschungen beim Geräteabgleich nicht zurückkommen.
    public private(set) var deletedIds: Set<UUID>

    public init(entries: [WaterEntry] = [], deletedIds: Set<UUID> = []) {
        self.entries = entries.sorted { $0.date < $1.date }
        self.deletedIds = deletedIds
    }

    public mutating func add(_ milliliters: Int, at date: Date = Date()) -> WaterEntry {
        let entry = WaterEntry(date: date, milliliters: milliliters)
        entries.append(entry)
        entries.sort { $0.date < $1.date }
        return entry
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        deletedIds.insert(id)
    }

    public func entries(on day: DayKey, calendar: Calendar = .current) -> [WaterEntry] {
        entries.filter { DayKey($0.date, calendar: calendar) == day }
    }

    public func total(on day: DayKey, calendar: Calendar = .current) -> Int {
        entries(on: day, calendar: calendar).reduce(0) { $0 + $1.milliliters }
    }

    public func dailyTotals(endingOn day: DayKey, days: Int, calendar: Calendar = .current) -> [(day: DayKey, milliliters: Int)] {
        DayKey.range(from: day.adding(days: -(days - 1), calendar: calendar), days: days, calendar: calendar)
            .map { ($0, total(on: $0, calendar: calendar)) }
    }

    /// Anzahl aufeinanderfolgender Tage mit erreichtem Ziel (heute zählt mit, wenn bereits erreicht).
    public func streak(goal: Int, today: DayKey, calendar: Calendar = .current) -> Int {
        var count = 0
        var day = total(on: today, calendar: calendar) >= goal ? today : today.adding(days: -1, calendar: calendar)
        while total(on: day, calendar: calendar) >= goal {
            count += 1
            day = day.adding(days: -1, calendar: calendar)
        }
        return count
    }

    /// Vereinigt Einträge zweier Geräte.
    public func merged(with other: WaterLog) -> WaterLog {
        let deleted = deletedIds.union(other.deletedIds)
        var byId: [UUID: WaterEntry] = [:]
        for entry in entries + other.entries where !deleted.contains(entry.id) {
            byId[entry.id] = entry
        }
        return WaterLog(entries: Array(byId.values), deletedIds: deleted)
    }

    /// Hält das Protokoll klein: Einträge und Lösch-Marker älter als `days` Tage werden entfernt.
    public mutating func prune(olderThan days: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        entries.removeAll { $0.date < cutoff }
        if deletedIds.count > 2000 { deletedIds = Set(deletedIds.prefix(1000)) }
    }
}

public enum WaterSchedule {
    /// Wie viel bis zu einem Zeitpunkt getrunken sein sollte (linear über den Wachzeitraum, Ziel 1 h vor dem Schlafen).
    public static func expectedIntake(at time: TimeOfDay, goal: Int, wake: TimeOfDay, sleep: TimeOfDay) -> Int {
        let start = wake.minutesSinceMidnight
        let end = max(sleep.minutesSinceMidnight - 60, start + 60)
        let now = time.minutesSinceMidnight
        if now <= start { return 0 }
        if now >= end { return goal }
        let fraction = Double(now - start) / Double(end - start)
        return Int((Double(goal) * fraction / 50).rounded()) * 50
    }
}

public struct WeightEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var kilograms: Double

    public init(id: UUID = UUID(), day: DayKey, kilograms: Double) {
        self.id = id
        self.day = day
        self.kilograms = kilograms
    }
}
