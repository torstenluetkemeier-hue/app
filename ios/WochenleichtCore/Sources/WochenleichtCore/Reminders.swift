import Foundation

public enum ReminderIntensity: String, Codable, CaseIterable, Sendable, Identifiable {
    case normal, persistent, relentless

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .persistent: "Hartnäckig"
        case .relentless: "Penetrant"
        }
    }

    public var explanation: String {
        switch self {
        case .normal: "Wasser im gewählten Intervall, Mahlzeiten pünktlich."
        case .persistent: "Zusätzlich Nachhaken, wenn du hinter deinem Trinkziel liegst, und Abend-Check."
        case .relentless: "Halbes Intervall, solange du hinterherhinkst, Vorwarnung vor jeder Mahlzeit und tägliches Nachbohren."
        }
    }
}

public struct ReminderSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var intensity: ReminderIntensity
    public var wakeTime: TimeOfDay
    public var sleepTime: TimeOfDay
    public var waterIntervalMinutes: Int
    public var breakfastTime: TimeOfDay
    public var lunchTime: TimeOfDay
    public var snackTime: TimeOfDay
    public var dinnerTime: TimeOfDay
    public var eveningCheckTime: TimeOfDay
    /// Kalender-Wochentag (1 = Sonntag, 2 = Montag …)
    public var weighInWeekday: Int
    public var weighInTime: TimeOfDay
    public var shoppingReminderTime: TimeOfDay
    public var supermarketProximityAlerts: Bool

    public init(isEnabled: Bool = true, intensity: ReminderIntensity = .relentless,
                wakeTime: TimeOfDay = .init(hour: 7), sleepTime: TimeOfDay = .init(hour: 22),
                waterIntervalMinutes: Int = 60,
                breakfastTime: TimeOfDay = .init(hour: 7, minute: 30), lunchTime: TimeOfDay = .init(hour: 12, minute: 30),
                snackTime: TimeOfDay = .init(hour: 15, minute: 30), dinnerTime: TimeOfDay = .init(hour: 18, minute: 30),
                eveningCheckTime: TimeOfDay = .init(hour: 20, minute: 30),
                weighInWeekday: Int = 2, weighInTime: TimeOfDay = .init(hour: 7, minute: 15),
                shoppingReminderTime: TimeOfDay = .init(hour: 17, minute: 30),
                supermarketProximityAlerts: Bool = true) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.wakeTime = wakeTime
        self.sleepTime = sleepTime
        self.waterIntervalMinutes = waterIntervalMinutes
        self.breakfastTime = breakfastTime
        self.lunchTime = lunchTime
        self.snackTime = snackTime
        self.dinnerTime = dinnerTime
        self.eveningCheckTime = eveningCheckTime
        self.weighInWeekday = weighInWeekday
        self.weighInTime = weighInTime
        self.shoppingReminderTime = shoppingReminderTime
        self.supermarketProximityAlerts = supermarketProximityAlerts
    }

    public func time(for meal: MealType) -> TimeOfDay {
        switch meal {
        case .breakfast: breakfastTime
        case .lunch: lunchTime
        case .snack: snackTime
        case .dinner: dinnerTime
        }
    }
}

public struct PlannedReminder: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case water, meal, mealPrep, eveningCheck, weighIn, shopping, comeBack
    }

    public static let waterCategory = "WATER_REMINDER"
    public static let mealCategory = "MEAL_REMINDER"

    public let id: String
    public let kind: Kind
    public let fireDate: Date
    public let title: String
    public let body: String
    public let categoryIdentifier: String?
    public let userInfo: [String: String]
}

/// Berechnet alle lokalen Benachrichtigungen der nächsten Tage (iOS erlaubt max. 64 ausstehende).
public struct ReminderPlanner: Sendable {
    public static let maxPendingNotifications = 60

    public let catalog: RecipeCatalog
    public var calendar: Calendar

    public init(catalog: RecipeCatalog, calendar: Calendar = .current) {
        self.catalog = catalog
        self.calendar = calendar
    }

    public struct Input: Sendable {
        public var now: Date
        public var settings: ReminderSettings
        public var waterGoalMl: Int
        public var waterLog: WaterLog
        public var dayPlans: [DayPlan]
        public var dailyLimit: Int
        /// Erster geplanter Tag, für den noch nicht eingekauft wurde.
        public var nextUnshoppedDay: DayKey?
        public var openShoppingItems: Int
        public var lastWeighIn: DayKey?
        public var daysToSchedule: Int
        /// Obergrenze der zu planenden Benachrichtigungen (iOS: max. 64 inkl. Standort-Erinnerungen).
        public var maxCount: Int

        public init(now: Date, settings: ReminderSettings, waterGoalMl: Int, waterLog: WaterLog, dayPlans: [DayPlan],
                    dailyLimit: Int, nextUnshoppedDay: DayKey?, openShoppingItems: Int, lastWeighIn: DayKey?, daysToSchedule: Int = 3, maxCount: Int = ReminderPlanner.maxPendingNotifications) {
            self.now = now
            self.settings = settings
            self.waterGoalMl = waterGoalMl
            self.waterLog = waterLog
            self.dayPlans = dayPlans
            self.dailyLimit = dailyLimit
            self.nextUnshoppedDay = nextUnshoppedDay
            self.openShoppingItems = openShoppingItems
            self.lastWeighIn = lastWeighIn
            self.daysToSchedule = daysToSchedule
            self.maxCount = maxCount
        }
    }

    public func plan(_ input: Input) -> [PlannedReminder] {
        guard input.settings.isEnabled else { return [] }
        let today = DayKey(input.now, calendar: calendar)
        let days = DayKey.range(from: today, days: input.daysToSchedule, calendar: calendar)
        var reminders: [PlannedReminder] = []

        for day in days {
            reminders += waterReminders(on: day, today: today, input: input)
            reminders += mealReminders(on: day, input: input)
            if input.settings.intensity != .normal {
                reminders += eveningCheck(on: day, today: today, input: input)
            }
        }
        reminders += weighInReminder(days: days, input: input)
        reminders += shoppingReminder(today: today, input: input)
        reminders += comeBackReminders(input: input)

        let upcoming = reminders.filter { $0.fireDate > input.now }.sorted { $0.fireDate < $1.fireDate }
        // Der "Komm zurück"-Hinweis muss erhalten bleiben – er greift, wenn die App lange nicht geöffnet wurde.
        let comeBack = upcoming.filter { $0.kind == .comeBack }
        let others = upcoming.filter { $0.kind != .comeBack }
        return Array(others.prefix(max(input.maxCount - comeBack.count, 0))) + comeBack
    }

    private func id(_ kind: PlannedReminder.Kind, _ day: DayKey, _ suffix: String = "") -> String {
        "\(kind.rawValue)-\(day)\(suffix.isEmpty ? "" : "-\(suffix)")"
    }

    private func waterReminders(on day: DayKey, today: DayKey, input: Input) -> [PlannedReminder] {
        let s = input.settings
        let goal = max(input.waterGoalMl, WaterLog.minimumDailyGoalMl)
        let drunk = day == today ? input.waterLog.total(on: day, calendar: calendar) : 0
        guard drunk < goal else { return [] }

        let nowTime = TimeOfDay(input.now, calendar: calendar)
        let behind = day == today && drunk < WaterSchedule.expectedIntake(at: nowTime, goal: goal, wake: s.wakeTime, sleep: s.sleepTime)
        let interval = max(s.intervalForWater(behind: behind), 15)

        var result: [PlannedReminder] = []
        var minute = s.wakeTime.minutesSinceMidnight + 30
        let last = s.sleepTime.minutesSinceMidnight - 30
        while minute <= last {
            let time = TimeOfDay(minutesSinceMidnight: minute)
            let expected = WaterSchedule.expectedIntake(at: time, goal: goal, wake: s.wakeTime, sleep: s.sleepTime)
            let body: String
            if day == today {
                let missing = goal - drunk
                body = behind
                    ? "Du liegst hinter deinem Plan! Bis \(time) solltest du \(Format.liters(expected)) haben – dir fehlen insgesamt noch \(Format.liters(missing)). Jetzt ein großes Glas!"
                    : "Ziel bis \(time): \(Format.liters(expected)). Noch \(Format.liters(missing)) bis zu deinen \(Format.liters(goal)). Trink ein Glas Wasser."
            } else {
                body = "Ziel bis \(time): \(Format.liters(expected)) von \(Format.liters(goal)). Ein Glas Wasser, jetzt."
            }
            result.append(PlannedReminder(
                id: id(.water, day, time.description), kind: .water,
                fireDate: day.date(hour: time.hour, minute: time.minute, calendar: calendar),
                title: "💧 Wasser trinken", body: body,
                categoryIdentifier: PlannedReminder.waterCategory, userInfo: ["day": day.description]
            ))
            minute += interval
        }
        return result
    }

    private func mealReminders(on day: DayKey, input: Input) -> [PlannedReminder] {
        guard let plan = input.dayPlans.first(where: { $0.day == day }) else { return [] }
        var result: [PlannedReminder] = []
        for meal in plan.meals where !meal.isEaten {
            guard let recipe = catalog.recipe(meal.recipeId) else { continue }
            let time = input.settings.time(for: meal.mealType)
            let kcal = catalog.kcal(of: recipe) * meal.servings
            result.append(PlannedReminder(
                id: id(.meal, day, meal.id.uuidString), kind: .meal,
                fireDate: day.date(hour: time.hour, minute: time.minute, calendar: calendar),
                title: "🍽 \(meal.mealType.displayName): \(recipe.name)",
                body: "\(Format.servings(meal.servings)) · \(Format.kcal(kcal)). Halte dich an deinen Plan – Tageslimit \(input.dailyLimit) kcal. Tippe auf „Gegessen“, wenn du fertig bist.",
                categoryIdentifier: PlannedReminder.mealCategory,
                userInfo: ["day": day.description, "mealId": meal.id.uuidString]
            ))
            // Penetrant: Vorwarnung, damit rechtzeitig gekocht wird (nicht für Snacks).
            if input.settings.intensity == .relentless && meal.mealType != .snack && recipe.minutes >= 15 {
                let prepMinute = time.minutesSinceMidnight - recipe.minutes - 10
                if prepMinute > input.settings.wakeTime.minutesSinceMidnight {
                    let prep = TimeOfDay(minutesSinceMidnight: prepMinute)
                    result.append(PlannedReminder(
                        id: id(.mealPrep, day, meal.id.uuidString), kind: .mealPrep,
                        fireDate: day.date(hour: prep.hour, minute: prep.minute, calendar: calendar),
                        title: "👩‍🍳 Gleich kochen: \(recipe.name)",
                        body: "Dauert ca. \(recipe.minutes) Minuten. Wer plant, greift nicht zu Ungeplantem.",
                        categoryIdentifier: nil, userInfo: ["day": day.description]
                    ))
                }
            }
        }
        return result
    }

    private func eveningCheck(on day: DayKey, today: DayKey, input: Input) -> [PlannedReminder] {
        let time = input.settings.eveningCheckTime
        let goal = max(input.waterGoalMl, WaterLog.minimumDailyGoalMl)
        let drunk = day == today ? input.waterLog.total(on: day, calendar: calendar) : 0
        let openMeals = input.dayPlans.first(where: { $0.day == day })?.meals.filter { !$0.isEaten }.count ?? 0
        var parts: [String] = []
        if drunk < goal { parts.append("Wasser: \(day == today ? Format.liters(drunk) : "?") von \(Format.liters(goal))") }
        if openMeals > 0 { parts.append("\(openMeals) Mahlzeit(en) noch nicht abgehakt") }
        guard !parts.isEmpty || day != today else { return [] }
        return [PlannedReminder(
            id: id(.eveningCheck, day), kind: .eveningCheck,
            fireDate: day.date(hour: time.hour, minute: time.minute, calendar: calendar),
            title: "📋 Tagesbilanz",
            body: parts.isEmpty ? "Hast du heute alles protokolliert? Wasser und Mahlzeiten abhaken!" : parts.joined(separator: " · ") + ". Bring den Tag sauber zu Ende!",
            categoryIdentifier: nil, userInfo: ["day": day.description]
        )]
    }

    private func weighInReminder(days: [DayKey], input: Input) -> [PlannedReminder] {
        guard let day = days.first(where: { calendar.component(.weekday, from: $0.date(calendar: calendar)) == input.settings.weighInWeekday }) else { return [] }
        if let last = input.lastWeighIn, last == day { return [] }
        let time = input.settings.weighInTime
        return [PlannedReminder(
            id: id(.weighIn, day), kind: .weighIn,
            fireDate: day.date(hour: time.hour, minute: time.minute, calendar: calendar),
            title: "⚖️ Wiegetag", body: "Nüchtern auf die Waage und Gewicht eintragen – nur so siehst du deinen Fortschritt.",
            categoryIdentifier: nil, userInfo: [:]
        )]
    }

    private func shoppingReminder(today: DayKey, input: Input) -> [PlannedReminder] {
        guard let next = input.nextUnshoppedDay, input.openShoppingItems > 0 else { return [] }
        // Einkauf am Vortag des ersten nicht abgedeckten Tages, spätestens heute.
        var day = max(next.adding(days: -1, calendar: calendar), today)
        let time = input.settings.shoppingReminderTime
        var fire = day.date(hour: time.hour, minute: time.minute, calendar: calendar)
        if fire <= input.now {
            fire = input.now.addingTimeInterval(2 * 3600)
            day = DayKey(fire, calendar: calendar)
        }
        return [PlannedReminder(
            id: id(.shopping, day), kind: .shopping, fireDate: fire,
            title: "🛒 Einkauf fällig",
            body: "Für deinen Wochenplan fehlen noch \(input.openShoppingItems) Artikel. Deine Listen pro Supermarkt sind fertig.",
            categoryIdentifier: nil, userInfo: [:]
        )]
    }

    private func comeBackReminders(input: Input) -> [PlannedReminder] {
        let fire = input.now.addingTimeInterval(Double(input.daysToSchedule) * 86_400 - 3600)
        return [PlannedReminder(
            id: "comeBack", kind: .comeBack, fireDate: fire,
            title: "Du bist vom Plan abgekommen 😟",
            body: "Seit Tagen keine Einträge. Öffne Wochenleicht, damit deine Erinnerungen und dein Wochenplan weiterlaufen.",
            categoryIdentifier: nil, userInfo: [:]
        )]
    }
}

extension ReminderSettings {
    func intervalForWater(behind: Bool) -> Int {
        switch intensity {
        case .normal: return waterIntervalMinutes
        case .persistent: return behind ? max(waterIntervalMinutes * 3 / 4, 30) : waterIntervalMinutes
        case .relentless: return behind ? max(waterIntervalMinutes / 2, 20) : waterIntervalMinutes
        }
    }
}
