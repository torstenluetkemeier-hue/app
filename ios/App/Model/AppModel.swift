import Foundation
import Observation
import WochenleichtCore

/// Zentrale Zustandsverwaltung eines angemeldeten Benutzers.
@MainActor
@Observable
final class AppModel {
    enum SyncState: Equatable {
        case idle, syncing, failed(String)
    }

    let catalog: RecipeCatalog
    let user: AuthUser
    private(set) var data: AppData
    private(set) var syncState: SyncState = .idle
    private(set) var today: DayKey = DayKey(Date())

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let auth: AuthService
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var reminderTask: Task<Void, Never>?

    init(user: AuthUser, auth: AuthService, catalog: RecipeCatalog) {
        self.user = user
        self.auth = auth
        self.catalog = catalog
        self.store = LocalStore(userId: user.id)
        self.data = store.load() ?? AppData()
    }

    var needsOnboarding: Bool { data.profile == nil }
    var dailyLimit: Int { data.dailyLimit }
    var todayPlan: DayPlan? { data.plan(for: today) }
    var waterToday: Int { data.water.total(on: today) }
    var waterGoal: Int { max(data.waterGoalMl, WaterLog.minimumDailyGoalMl) }

    var expectedWaterNow: Int {
        WaterSchedule.expectedIntake(at: TimeOfDay(Date()), goal: waterGoal,
                                     wake: data.reminders.wakeTime, sleep: data.reminders.sleepTime)
    }

    var upcomingPlans: [DayPlan] { data.dayPlans.filter { $0.day >= today } }

    func recipe(for meal: PlannedMeal) -> Recipe? { catalog.recipe(meal.recipeId) }
    func kcal(for meal: PlannedMeal) -> Double { catalog.kcal(ofRecipeId: meal.recipeId) * meal.servings }

    // MARK: - Änderungen

    /// Jede Änderung läuft hierüber: speichern, Einkaufsliste aktualisieren, Erinnerungen neu planen, synchronisieren.
    func mutate(_ change: (inout AppData) -> Void) {
        var copy = data
        change(&copy)
        copy.refreshShoppingList(today: today, catalog: catalog)
        guard copy != data else { return }
        copy.touch()
        data = copy
        store.save(data)
        scheduleReminders()
        scheduleSync()
    }

    /// Bei App-Start, Rückkehr in den Vordergrund und Hintergrundaktualisierung.
    func refreshForNewDay() {
        today = DayKey(Date())
        mutate { data in
            data.ensurePlanned(today: today, catalog: catalog)
            data.water.prune(olderThan: 400)
        }
        scheduleReminders()
    }

    func completeOnboarding(profile: UserProfile, waterGoal: Int, stapleIds: Set<String>, reminders: ReminderSettings) {
        mutate { data in
            data.profile = profile
            data.waterGoalMl = max(waterGoal, WaterLog.minimumDailyGoalMl)
            data.reminders = reminders
            for id in stapleIds {
                guard let ingredient = catalog.ingredient(id) else { continue }
                data.pantry.setQuantity(ingredient.packageSize, for: id)
            }
            data.logWeight(profile.currentWeightKg, on: today)
            data.ensurePlanned(today: today, catalog: catalog)
        }
    }

    func updateProfile(_ profile: UserProfile, replan: Bool) {
        mutate { data in
            data.profile = profile
            if replan {
                data.replanUnshopped(from: today, catalog: catalog)
            } else {
                data.rebalance(from: today, catalog: catalog)
            }
        }
    }

    func logWater(_ milliliters: Int, at date: Date = Date()) {
        mutate { _ = $0.water.add(milliliters, at: date) }
    }

    func removeWater(_ id: UUID) {
        mutate { $0.water.remove(id: id) }
    }

    func setWaterGoal(_ milliliters: Int) {
        mutate { $0.waterGoalMl = max(milliliters, WaterLog.minimumDailyGoalMl) }
    }

    func setEaten(_ eaten: Bool, day: DayKey, mealId: UUID) {
        mutate { $0.setEaten(eaten, day: day, mealId: mealId, catalog: catalog) }
    }

    func replaceMeal(day: DayKey, mealId: UUID, recipeId: String, servings: Double) {
        mutate { $0.replaceMeal(day: day, mealId: mealId, with: recipeId, servings: servings) }
    }

    func setServings(_ servings: Double, day: DayKey, mealId: UUID) {
        guard let meal = data.plan(for: day)?.meals.first(where: { $0.id == mealId }) else { return }
        replaceMeal(day: day, mealId: mealId, recipeId: meal.recipeId, servings: servings)
    }

    func regenerate(day: DayKey) {
        mutate { $0.regenerate(day: day, catalog: catalog) }
    }

    func alternatives(for meal: PlannedMeal, on day: DayKey) -> [(recipe: Recipe, servings: Double)] {
        guard let plan = data.plan(for: day) else { return [] }
        let planner = MealPlanner(catalog: catalog, dislikedRecipeIds: data.dislikedRecipeIds)
        return planner.alternatives(for: meal, in: plan, limit: dailyLimit,
                                    context: .init(preferredIngredientIds: data.pantry.nonEmptyIngredientIds), count: 12)
    }

    func toggleDisliked(_ recipeId: String) {
        mutate { data in
            if data.dislikedRecipeIds.contains(recipeId) {
                data.dislikedRecipeIds.remove(recipeId)
            } else {
                data.dislikedRecipeIds.insert(recipeId)
            }
        }
    }

    // MARK: Einkauf & Vorrat

    func setChecked(_ checked: Bool, ingredientId: String) {
        mutate { $0.setChecked(checked, ingredientId: ingredientId) }
    }

    func completeShopping() {
        mutate { $0.completeShopping(today: today, catalog: catalog) }
    }

    func setPantryQuantity(_ quantity: Double, ingredientId: String) {
        mutate { $0.pantry.setQuantity(quantity, for: ingredientId) }
    }

    func setStores(_ stores: [Supermarket]) {
        mutate { data in
            data.stores = stores
            data.storeAssignment.prune(validStoreIds: Set(stores.map(\.id)))
            if data.storeAssignment.defaultStoreId == nil {
                data.storeAssignment.defaultStoreId = stores.first?.id
            }
        }
    }

    func setDefaultStore(_ storeId: String) {
        mutate { $0.storeAssignment.defaultStoreId = storeId }
    }

    func assign(category: IngredientCategory, to storeId: String?) {
        mutate { $0.storeAssignment.categoryStores[category.rawValue] = storeId }
    }

    func assign(ingredientId: String, to storeId: String) {
        mutate { $0.storeAssignment.ingredientStores[ingredientId] = storeId }
    }

    func logWeight(_ kilograms: Double) {
        mutate { $0.logWeight(kilograms, on: today) }
    }

    func updateReminders(_ settings: ReminderSettings) {
        mutate { $0.reminders = settings }
    }

    // MARK: Erinnerungen

    func scheduleReminders() {
        reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.rescheduleNow()
        }
    }

    func rescheduleNow() async {
        let snapshot = data
        let planner = ReminderPlanner(catalog: catalog)
        let today = today
        await NotificationService.shared.reschedule(
            reminders: { maxCount in
                planner.plan(.init(
                    now: Date(), settings: snapshot.reminders, waterGoalMl: snapshot.waterGoalMl, waterLog: snapshot.water,
                    dayPlans: snapshot.dayPlans, dailyLimit: snapshot.dailyLimit,
                    nextUnshoppedDay: snapshot.nextUnshoppedDay(from: today),
                    openShoppingItems: snapshot.shoppingList?.openItemCount ?? 0,
                    lastWeighIn: snapshot.weights.last?.day, maxCount: maxCount
                ))
            },
            stores: snapshot.stores,
            openShoppingItems: snapshot.shoppingList?.openItemCount ?? 0,
            proximityAlerts: snapshot.reminders.supermarketProximityAlerts && snapshot.reminders.isEnabled
        )
    }

    // MARK: Synchronisation

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    func syncNow() async {
        guard syncState != .syncing else { return }
        syncState = .syncing
        let sent = data
        do {
            let merged = try await SyncService(auth: auth, store: store).synchronize(local: sent)
            // Nur übernehmen, was sich während des Syncs lokal nicht geändert hat; sonst erneut zusammenführen.
            let result = data == sent ? merged : data.merged(with: merged)
            if result != data {
                data = result
                data.refreshShoppingList(today: today, catalog: catalog)
                store.save(data)
                scheduleReminders()
            }
            syncState = .idle
            if data != merged { scheduleSync() }
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    func deleteLocalData() {
        store.delete()
    }
}
