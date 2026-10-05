import Foundation

public enum Sex: String, Codable, CaseIterable, Sendable, Identifiable {
    case female, male
    public var id: String { rawValue }
    public var displayName: String { self == .female ? "Weiblich" : "Männlich" }
}

public enum ActivityLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case sedentary, light, moderate, active

    public var id: String { rawValue }

    public var factor: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        }
    }

    public var displayName: String {
        switch self {
        case .sedentary: "Kaum aktiv (Bürojob)"
        case .light: "Leicht aktiv (1–2× Sport/Woche)"
        case .moderate: "Mäßig aktiv (3–5× Sport/Woche)"
        case .active: "Sehr aktiv (täglich Sport)"
        }
    }
}

public struct UserProfile: Codable, Hashable, Sendable {
    public var sex: Sex
    public var age: Int
    public var heightCm: Double
    public var currentWeightKg: Double
    public var targetWeightKg: Double
    public var activity: ActivityLevel
    /// Gewünschte Abnahme pro Woche – nachhaltig sind 0,25–0,75 kg.
    public var weeklyLossKg: Double
    /// Manuell gesetzte Kalorienobergrenze; überschreibt die Berechnung.
    public var calorieLimitOverride: Int?
    public var includeSnack: Bool

    public init(sex: Sex = .female, age: Int = 35, heightCm: Double = 170, currentWeightKg: Double = 80,
                targetWeightKg: Double = 70, activity: ActivityLevel = .light, weeklyLossKg: Double = 0.5,
                calorieLimitOverride: Int? = nil, includeSnack: Bool = true) {
        self.sex = sex
        self.age = age
        self.heightCm = heightCm
        self.currentWeightKg = currentWeightKg
        self.targetWeightKg = targetWeightKg
        self.activity = activity
        self.weeklyLossKg = weeklyLossKg
        self.calorieLimitOverride = calorieLimitOverride
        self.includeSnack = includeSnack
    }

    public var mealTypes: [MealType] {
        includeSnack ? [.breakfast, .lunch, .snack, .dinner] : [.breakfast, .lunch, .dinner]
    }

    public var bmi: Double {
        let meters = heightCm / 100
        return currentWeightKg / (meters * meters)
    }
}

public enum CalorieCalculator {
    /// 1 kg Körperfett ≈ 7700 kcal.
    public static let kcalPerKgFat = 7700.0

    /// Grundumsatz nach Mifflin-St Jeor.
    public static func basalMetabolicRate(_ p: UserProfile) -> Double {
        let base = 10 * p.currentWeightKg + 6.25 * p.heightCm - 5 * Double(p.age)
        return base + (p.sex == .male ? 5 : -161)
    }

    public static func totalEnergyExpenditure(_ p: UserProfile) -> Double {
        basalMetabolicRate(p) * p.activity.factor
    }

    /// Untergrenze, unter die eine Diät ohne ärztliche Begleitung nicht fallen sollte.
    public static func minimumIntake(_ p: UserProfile) -> Int {
        p.sex == .male ? 1500 : 1200
    }

    /// Tägliche Kalorienobergrenze (auf 50 kcal gerundet), nie unter dem Minimum.
    public static func dailyLimit(_ p: UserProfile) -> Int {
        if let override = p.calorieLimitOverride {
            return max(override, minimumIntake(p))
        }
        let weekly = min(max(p.weeklyLossKg, 0), 1.0)
        let deficit = weekly * kcalPerKgFat / 7
        let target = totalEnergyExpenditure(p) - deficit
        let rounded = Int((target / 50).rounded()) * 50
        return max(rounded, minimumIntake(p))
    }

    /// Anteil der Tageskalorien je Mahlzeit.
    public static func share(of meal: MealType, includeSnack: Bool) -> Double {
        switch (meal, includeSnack) {
        case (.breakfast, true): 0.25
        case (.lunch, true): 0.35
        case (.snack, true): 0.10
        case (.dinner, true): 0.30
        case (.breakfast, false): 0.30
        case (.lunch, false): 0.40
        case (.dinner, false): 0.30
        case (.snack, false): 0
        }
    }

    /// Geschätzte Wochen bis zum Zielgewicht.
    public static func weeksToGoal(_ p: UserProfile) -> Int? {
        let toLose = p.currentWeightKg - p.targetWeightKg
        guard toLose > 0, p.weeklyLossKg > 0 else { return nil }
        return Int((toLose / p.weeklyLossKg).rounded(.up))
    }
}
