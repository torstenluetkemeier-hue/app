import Foundation

/// Gesamter App-Zustand – lokal als JSON gespeichert und mit dem Server synchronisiert.
public struct AppData: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    /// Die App plant immer mindestens so viele Tage im Voraus.
    public static let planningHorizonDays = 7
    public static let historyDays = 60

    public var schemaVersion: Int
    public var profile: UserProfile?
    public var dayPlans: [DayPlan]
    public var pantry: Pantry
    public var water: WaterLog
    public var waterGoalMl: Int
    public var weights: [WeightEntry]
    public var shoppingList: ShoppingList?
    public var stores: [Supermarket]
    public var storeAssignment: StoreAssignment
    public var reminders: ReminderSettings
    public var dislikedRecipeIds: Set<String>
    public var modifiedAt: Date

    public init(profile: UserProfile? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.profile = profile
        dayPlans = []
        pantry = Pantry()
        water = WaterLog()
        waterGoalMl = WaterLog.minimumDailyGoalMl
        weights = []
        shoppingList = nil
        stores = []
        storeAssignment = StoreAssignment()
        reminders = ReminderSettings()
        dislikedRecipeIds = []
        modifiedAt = Date(timeIntervalSince1970: 0)
    }

    public var dailyLimit: Int {
        profile.map(CalorieCalculator.dailyLimit) ?? 1800
    }

    public func plan(for day: DayKey) -> DayPlan? {
        dayPlans.first { $0.day == day }
    }

    private func index(of day: DayKey) -> Int? {
        dayPlans.firstIndex { $0.day == day }
    }

    private func planner(_ catalog: RecipeCatalog) -> MealPlanner {
        MealPlanner(catalog: catalog, dislikedRecipeIds: dislikedRecipeIds)
    }

    private func planningContext(before day: DayKey, catalog: RecipeCatalog) -> MealPlanner.Context {
        let previous = dayPlans.filter { $0.day < day }.sorted { $0.day < $1.day }.suffix(3)
        var preferred = pantry.nonEmptyIngredientIds
        for plan in dayPlans where plan.day >= day {
            for meal in plan.meals {
                catalog.recipe(meal.recipeId)?.ingredients.forEach { preferred.insert($0.ingredientId) }
            }
        }
        return .init(recentRecipeIds: previous.flatMap { $0.meals.map(\.recipeId) }, preferredIngredientIds: preferred)
    }

    // MARK: - Wochenplanung

    /// Stellt sicher, dass heute und die folgenden Tage (Planungshorizont) geplant sind. Gibt true zurück, wenn etwas geändert wurde.
    @discardableResult
    public mutating func ensurePlanned(today: DayKey, catalog: RecipeCatalog, calendar: Calendar = .current, seed: UInt64? = nil) -> Bool {
        guard let profile else { return false }
        let oldest = today.adding(days: -Self.historyDays, calendar: calendar)
        let before = dayPlans.count
        dayPlans.removeAll { $0.day < oldest }
        var changed = dayPlans.count != before

        let missing = DayKey.range(from: today, days: Self.planningHorizonDays, calendar: calendar).filter { plan(for: $0) == nil }
        if !missing.isEmpty {
            let planner = planner(catalog)
            let effectiveSeed = seed ?? UInt64.random(in: 0...UInt64.max)
            for (offset, day) in missing.enumerated() {
                let new = planner.planDays([day], limit: dailyLimit, mealTypes: profile.mealTypes,
                                           context: planningContext(before: day, catalog: catalog), seed: effectiveSeed &+ UInt64(offset))
                dayPlans.append(contentsOf: new)
                dayPlans.sort { $0.day < $1.day }
            }
            changed = true
        }
        return changed
    }

    /// Plant einen Tag neu (bereits gegessene Mahlzeiten bleiben erhalten).
    public mutating func regenerate(day: DayKey, catalog: RecipeCatalog, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        guard let profile, let i = index(of: day) else { return }
        let eaten = dayPlans[i].meals.filter(\.isEaten)
        var context = planningContext(before: day, catalog: catalog)
        context.recentRecipeIds += dayPlans[i].meals.map(\.recipeId)
        let remainingTypes = profile.mealTypes.filter { type in !eaten.contains { $0.mealType == type } }
        var fresh = planner(catalog).planDays([day], limit: dailyLimit, mealTypes: remainingTypes, context: context, seed: seed)[0]
        fresh.meals = (eaten + fresh.meals).sorted { profile.mealTypes.firstIndex(of: $0.mealType) ?? 0 < profile.mealTypes.firstIndex(of: $1.mealType) ?? 0 }
        fresh.isShopped = dayPlans[i].isShopped
        planner(catalog).balance(&fresh, limit: dailyLimit)
        dayPlans[i] = fresh
    }

    /// Plant alle noch nicht eingekauften zukünftigen Tage neu (z. B. nach Profiländerung).
    public mutating func replanUnshopped(from today: DayKey, catalog: RecipeCatalog) {
        for plan in dayPlans where plan.day >= today && !plan.isShopped {
            regenerate(day: plan.day, catalog: catalog)
        }
        rebalance(from: today, catalog: catalog)
    }

    /// Passt Portionsgrößen aller zukünftigen Tage an die aktuelle Kalorienobergrenze an.
    public mutating func rebalance(from today: DayKey, catalog: RecipeCatalog) {
        let planner = planner(catalog)
        for i in dayPlans.indices where dayPlans[i].day >= today {
            planner.balance(&dayPlans[i], limit: dailyLimit)
        }
    }

    public mutating func replaceMeal(day: DayKey, mealId: UUID, with recipeId: String, servings: Double) {
        guard let i = index(of: day), let m = dayPlans[i].meals.firstIndex(where: { $0.id == mealId }) else { return }
        dayPlans[i].meals[m].recipeId = recipeId
        dayPlans[i].meals[m].servings = MealPlanner.roundServings(servings)
    }

    /// Markiert eine Mahlzeit als gegessen und bucht die Zutaten aus dem Vorrat aus (bzw. zurück).
    public mutating func setEaten(_ eaten: Bool, day: DayKey, mealId: UUID, catalog: RecipeCatalog) {
        guard let i = index(of: day), let m = dayPlans[i].meals.firstIndex(where: { $0.id == mealId }),
              dayPlans[i].meals[m].isEaten != eaten else { return }
        dayPlans[i].meals[m].isEaten = eaten
        let usage = IngredientMath.requirements(for: [dayPlans[i].meals[m]], catalog: catalog)
        for (ingredientId, amount) in usage {
            if eaten {
                pantry.consume(ingredientId, amount: amount)
            } else if let ingredient = catalog.ingredient(ingredientId) {
                pantry.setQuantity(pantry.quantity(of: ingredientId) + amount, for: ingredient.id)
            }
        }
    }

    // MARK: - Vorrat & Einkauf

    /// Zutaten, die für bereits eingekaufte, noch nicht gegessene Mahlzeiten verplant sind.
    public func reservations(from today: DayKey, excluding excludedDays: Set<DayKey> = [], catalog: RecipeCatalog) -> [String: Double] {
        let meals = dayPlans
            .filter { $0.day >= today && $0.isShopped && !excludedDays.contains($0.day) }
            .flatMap { $0.meals.filter { !$0.isEaten } }
        return IngredientMath.requirements(for: meals, catalog: catalog)
    }

    /// Vorrat mit Angabe, was nach allen geplanten Mahlzeiten übrig bleibt.
    public func pantryProjection(today: DayKey, catalog: RecipeCatalog) -> [PantryProjection] {
        PantryProjection.build(pantry: pantry, reservations: reservations(from: today, catalog: catalog), catalog: catalog)
    }

    public func unshoppedDays(from today: DayKey) -> [DayPlan] {
        dayPlans.filter { $0.day >= today && !$0.isShopped }.sorted { $0.day < $1.day }
    }

    public func nextUnshoppedDay(from today: DayKey) -> DayKey? {
        unshoppedDays(from: today).first?.day
    }

    /// Aktualisiert die Einkaufsliste für alle geplanten, noch nicht eingekauften Tage.
    public mutating func refreshShoppingList(today: DayKey, catalog: RecipeCatalog, now: Date = Date()) {
        let target = unshoppedDays(from: today)
        guard !target.isEmpty else {
            shoppingList = nil
            return
        }
        shoppingList = ShoppingListBuilder.build(
            targetDays: target, pantry: pantry,
            reservations: reservations(from: today, catalog: catalog),
            catalog: catalog, previous: shoppingList, now: now
        )
    }

    /// Schließt den Einkauf ab: abgehakte Artikel wandern in den Vorrat, die Tage gelten als eingekauft.
    public mutating func completeShopping(today: DayKey, catalog: RecipeCatalog, calendar: Calendar = .current) {
        guard let list = shoppingList else { return }
        for item in list.items where item.isChecked {
            guard let ingredient = catalog.ingredient(item.ingredientId) else { continue }
            pantry.add(ingredient, amount: item.purchaseAmount, purchasedOn: today, calendar: calendar)
        }
        let days = Set(list.days)
        for i in dayPlans.indices where days.contains(dayPlans[i].day) {
            dayPlans[i].isShopped = true
        }
        shoppingList = nil
    }

    public mutating func setChecked(_ checked: Bool, ingredientId: String) {
        guard let list = shoppingList, let i = list.items.firstIndex(where: { $0.ingredientId == ingredientId }) else { return }
        shoppingList?.items[i].isChecked = checked
    }

    // MARK: - Gewicht

    public mutating func logWeight(_ kilograms: Double, on day: DayKey) {
        weights.removeAll { $0.day == day }
        weights.append(WeightEntry(day: day, kilograms: kilograms))
        weights.sort { $0.day < $1.day }
        if let latest = weights.last, latest.day == day {
            profile?.currentWeightKg = kilograms
        }
    }

    // MARK: - Synchronisation

    /// Führt lokalen und entfernten Stand zusammen: Wasser wird vereinigt, sonst gewinnt der neuere Stand.
    public func merged(with remote: AppData) -> AppData {
        var result = remote.modifiedAt > modifiedAt ? remote : self
        result.water = water.merged(with: remote.water)
        result.modifiedAt = max(modifiedAt, remote.modifiedAt)
        return result
    }

    public mutating func touch(_ date: Date = Date()) {
        modifiedAt = max(date, modifiedAt.addingTimeInterval(0.001))
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
