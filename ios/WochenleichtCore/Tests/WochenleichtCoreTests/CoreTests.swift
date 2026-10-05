import XCTest
@testable import WochenleichtCore

final class CoreTests: XCTestCase {
    var catalog: RecipeCatalog!
    var calendar: Calendar!
    let today = DayKey(year: 2026, month: 10, day: 5) // Montag

    override func setUpWithError() throws {
        catalog = try RecipeCatalog.bundled()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    }

    func makeData(limit: Int = 1800) -> AppData {
        AppData(profile: UserProfile(calorieLimitOverride: limit))
    }

    // MARK: Katalog

    func testCatalogLoadsAndCoversAllMealTypes() {
        XCTAssertGreaterThanOrEqual(catalog.recipes.count, 40)
        for type in MealType.allCases {
            XCTAssertGreaterThanOrEqual(catalog.recipes(for: type).count, 5, "\(type)")
        }
        for recipe in catalog.recipes {
            XCTAssertGreaterThan(catalog.kcal(of: recipe), 50, recipe.id)
            XCTAssertFalse(recipe.steps.isEmpty, recipe.id)
        }
    }

    func testSuggestionsRespectCalorieLimit() {
        let suggestions = catalog.suggestions(maxKcal: 300, mealType: .breakfast)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { catalog.kcal(of: $0) <= 300 })
        XCTAssertTrue(catalog.suggestions(maxKcal: 600, searchText: "lachs").contains { $0.id == "ofenlachs" })
    }

    // MARK: Kalorien

    func testCalorieLimitHasSafeFloor() {
        let small = UserProfile(sex: .female, age: 60, heightCm: 150, currentWeightKg: 50, activity: .sedentary, weeklyLossKg: 1)
        XCTAssertEqual(CalorieCalculator.dailyLimit(small), 1200)
        let man = UserProfile(sex: .male, age: 40, heightCm: 185, currentWeightKg: 100, activity: .moderate, weeklyLossKg: 0.5)
        // BMR = 1000 + 1156.25 - 200 + 5 = 1961.25; TDEE = 3039.9; −550 = 2489.9 → 2500
        XCTAssertEqual(CalorieCalculator.dailyLimit(man), 2500)
        XCTAssertEqual(CalorieCalculator.dailyLimit(UserProfile(sex: .male, calorieLimitOverride: 1000)), 1500)
    }

    // MARK: Planung

    func testPlannerStaysUnderLimitAndFillsDay() {
        for limit in [1200, 1500, 1800, 2200, 2600] {
            var data = makeData(limit: limit)
            data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 42)
            XCTAssertEqual(data.dayPlans.count, 7)
            for plan in data.dayPlans {
                let total = plan.totalKcal(in: catalog)
                XCTAssertLessThanOrEqual(total, Double(limit) + 0.01, "limit \(limit) day \(plan.day)")
                XCTAssertGreaterThanOrEqual(total, Double(limit) * 0.8, "limit \(limit) day \(plan.day)")
                XCTAssertEqual(plan.meals.map(\.mealType), [.breakfast, .lunch, .snack, .dinner])
            }
        }
    }

    func testPlannerAvoidsRepeatsWithinWeek() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 7)
        let dinners = data.dayPlans.compactMap { $0.meals.first { $0.mealType == .dinner }?.recipeId }
        XCTAssertGreaterThanOrEqual(Set(dinners).count, 5, "\(dinners)")
    }

    func testPlanningIsRollingAndKeepsOneWeekAhead() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 1)
        let firstWeek = data.dayPlans
        let later = today.adding(days: 3, calendar: calendar)
        XCTAssertTrue(data.ensurePlanned(today: later, catalog: catalog, calendar: calendar, seed: 2))
        XCTAssertEqual(data.dayPlans.count, 10)
        XCTAssertEqual(Array(data.dayPlans.prefix(7)), firstWeek, "bestehende Tage bleiben unverändert")
        XCTAssertEqual(data.dayPlans.last?.day, later.adding(days: 6, calendar: calendar))
        XCTAssertFalse(data.ensurePlanned(today: later, catalog: catalog, calendar: calendar))
    }

    func testRegenerateKeepsEatenMeals() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 3)
        let breakfast = data.plan(for: today)!.meals[0]
        data.setEaten(true, day: today, mealId: breakfast.id, catalog: catalog)
        data.regenerate(day: today, catalog: catalog, seed: 99)
        let plan = data.plan(for: today)!
        XCTAssertEqual(plan.meals.first, { var b = breakfast; b.isEaten = true; return b }())
        XCTAssertEqual(plan.meals.count, 4)
        XCTAssertLessThanOrEqual(plan.totalKcal(in: catalog), 1800.01)
    }

    func testAlternativesFitRemainingBudget() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 3)
        let plan = data.plan(for: today)!
        let lunch = plan.meals.first { $0.mealType == .lunch }!
        let planner = MealPlanner(catalog: catalog)
        let alternatives = planner.alternatives(for: lunch, in: plan, limit: 1800, context: .init())
        XCTAssertFalse(alternatives.isEmpty)
        let others = plan.totalKcal(in: catalog) - catalog.kcal(ofRecipeId: lunch.recipeId) * lunch.servings
        for alt in alternatives where alt.servings > MealPlanner.minServings {
            XCTAssertLessThanOrEqual(others + catalog.kcal(of: alt.recipe) * alt.servings, 1800.01, alt.recipe.id)
        }
    }

    // MARK: Einkauf & Vorrat

    func testShoppingListRoundsUpToPackagesAndTracksLeftovers() {
        var data = makeData()
        data.dayPlans = [DayPlan(day: today, meals: [PlannedMeal(mealType: .lunch, recipeId: "linsen_dal")])]
        data.refreshShoppingList(today: today, catalog: catalog)
        let list = data.shoppingList!
        let lentils = list.items.first { $0.ingredientId == "rote_linsen" }!
        XCTAssertEqual(lentils.neededAmount, 70, accuracy: 0.001)
        XCTAssertEqual(lentils.packages, 1)
        XCTAssertEqual(lentils.purchaseAmount, 500)
        XCTAssertEqual(lentils.leftoverAmount, 430, accuracy: 0.001)

        for item in list.items { data.setChecked(true, ingredientId: item.ingredientId) }
        data.completeShopping(today: today, catalog: catalog, calendar: calendar)
        XCTAssertNil(data.shoppingList)
        XCTAssertTrue(data.plan(for: today)!.isShopped)
        XCTAssertEqual(data.pantry.quantity(of: "rote_linsen"), 500)

        // Vorrat zeigt: nach dem Kochen sollten 430 g übrig sein
        let projection = data.pantryProjection(today: today, catalog: catalog).first { $0.id == "rote_linsen" }!
        XCTAssertEqual(projection.remainingAfterPlan, 430, accuracy: 0.001)

        // Gegessen → Vorrat sinkt tatsächlich
        data.setEaten(true, day: today, mealId: data.plan(for: today)!.meals[0].id, catalog: catalog)
        XCTAssertEqual(data.pantry.quantity(of: "rote_linsen"), 430, accuracy: 0.001)
        // Rückgängig → wieder da
        data.setEaten(false, day: today, mealId: data.plan(for: today)!.meals[0].id, catalog: catalog)
        XCTAssertEqual(data.pantry.quantity(of: "rote_linsen"), 500, accuracy: 0.001)
    }

    func testLeftoversReduceNextShoppingList() {
        var data = makeData()
        let tomorrow = today.adding(days: 1, calendar: calendar)
        data.pantry.setQuantity(430, for: "rote_linsen")
        data.pantry.setQuantity(500, for: "salz")
        data.dayPlans = [DayPlan(day: tomorrow, meals: [PlannedMeal(mealType: .lunch, recipeId: "linsen_dal")])]
        data.refreshShoppingList(today: today, catalog: catalog)
        let ids = Set(data.shoppingList!.items.map(\.ingredientId))
        XCTAssertFalse(ids.contains("rote_linsen"), "Reste aus dem Vorrat werden verwendet")
        XCTAssertFalse(ids.contains("salz"), "Gewürz ist vorrätig")
        XCTAssertTrue(ids.contains("currypulver"), "fehlendes Gewürz wird gekauft")
    }

    func testReservedPantryItemsAreNotDoubleCounted() {
        var data = makeData()
        let tomorrow = today.adding(days: 1, calendar: calendar)
        // Heute ist schon eingekauft und braucht 70 g Linsen; Vorrat hat genau 100 g.
        data.pantry.setQuantity(100, for: "rote_linsen")
        data.dayPlans = [
            DayPlan(day: today, meals: [PlannedMeal(mealType: .lunch, recipeId: "linsen_dal")], isShopped: true),
            DayPlan(day: tomorrow, meals: [PlannedMeal(mealType: .lunch, recipeId: "linsen_dal")]),
        ]
        data.refreshShoppingList(today: today, catalog: catalog)
        let lentils = data.shoppingList!.items.first { $0.ingredientId == "rote_linsen" }!
        XCTAssertEqual(lentils.neededAmount, 40, accuracy: 0.001) // 70 benötigt − (100 − 70 reserviert)
        XCTAssertEqual(data.shoppingList!.days, [tomorrow])
    }

    func testRefreshKeepsCheckedState() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 5)
        data.refreshShoppingList(today: today, catalog: catalog)
        let first = data.shoppingList!.items[0].ingredientId
        data.setChecked(true, ingredientId: first)
        data.refreshShoppingList(today: today, catalog: catalog)
        XCTAssertTrue(data.shoppingList!.items.first { $0.ingredientId == first }!.isChecked)
    }

    func testGroupingByStore() {
        let rewe = Supermarket(id: "r", name: "REWE Markt", address: "", latitude: 52.5, longitude: 13.4)
        let aldi = Supermarket(id: "a", name: "ALDI Nord", address: "", latitude: 52.5, longitude: 13.41)
        XCTAssertEqual(rewe.chain, "Rewe")
        XCTAssertEqual(aldi.chain, "Aldi")
        var data = makeData()
        data.stores = [rewe, aldi]
        data.storeAssignment = StoreAssignment(defaultStoreId: "r", categoryStores: [IngredientCategory.spices.rawValue: "a"], ingredientStores: ["olivenoel": "a"])
        data.dayPlans = [DayPlan(day: today, meals: [PlannedMeal(mealType: .lunch, recipeId: "linsen_dal")])]
        data.refreshShoppingList(today: today, catalog: catalog)
        let groups = data.shoppingList!.grouped(stores: data.stores, assignment: data.storeAssignment, catalog: catalog)
        XCTAssertEqual(groups.map(\.store?.id), ["a", "r"])
        let aldiIds = groups[0].sections.flatMap { $0.items.map(\.ingredientId) }
        XCTAssertTrue(aldiIds.contains("olivenoel"))
        XCTAssertTrue(aldiIds.contains("currypulver"))
        XCTAssertFalse(aldiIds.contains("spinat"))
        // Sektionen nach Gang sortiert
        let orders = groups[1].sections.map(\.category.aisleOrder)
        XCTAssertEqual(orders, orders.sorted())
    }

    // MARK: Wasser

    func testWaterTotalsStreakAndMerge() {
        var log = WaterLog()
        let day1 = today.date(hour: 10, minute: 0, calendar: calendar)
        let day0 = today.adding(days: -1, calendar: calendar).date(hour: 10, minute: 0, calendar: calendar)
        _ = log.add(3000, at: day0)
        _ = log.add(1000, at: day1)
        let entry = log.add(500, at: day1.addingTimeInterval(60))
        XCTAssertEqual(log.total(on: today, calendar: calendar), 1500)
        XCTAssertEqual(log.streak(goal: 3000, today: today, calendar: calendar), 1)

        var other = log
        _ = other.add(250, at: day1.addingTimeInterval(120))
        log.remove(id: entry.id)
        let merged = log.merged(with: other)
        XCTAssertEqual(merged.total(on: today, calendar: calendar), 1250, "Löschung bleibt, neuer Eintrag kommt dazu")
    }

    func testExpectedWaterIntake() {
        let wake = TimeOfDay(hour: 7), sleep = TimeOfDay(hour: 22)
        XCTAssertEqual(WaterSchedule.expectedIntake(at: TimeOfDay(hour: 6), goal: 3000, wake: wake, sleep: sleep), 0)
        XCTAssertEqual(WaterSchedule.expectedIntake(at: TimeOfDay(hour: 14), goal: 3000, wake: wake, sleep: sleep), 1500)
        XCTAssertEqual(WaterSchedule.expectedIntake(at: TimeOfDay(hour: 21, minute: 30), goal: 3000, wake: wake, sleep: sleep), 3000)
    }

    // MARK: Erinnerungen

    func testRemindersRespectLimitAndSkipReachedWaterGoal() {
        var data = makeData()
        data.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 1)
        data.refreshShoppingList(today: today, catalog: catalog)
        let now = today.date(hour: 9, minute: 0, calendar: calendar)
        let planner = ReminderPlanner(catalog: catalog, calendar: calendar)
        func input(_ log: WaterLog) -> ReminderPlanner.Input {
            .init(now: now, settings: data.reminders, waterGoalMl: 3000, waterLog: log, dayPlans: data.dayPlans,
                  dailyLimit: 1800, nextUnshoppedDay: data.nextUnshoppedDay(from: today),
                  openShoppingItems: data.shoppingList?.openItemCount ?? 0, lastWeighIn: nil)
        }
        let reminders = planner.plan(input(WaterLog()))
        XCTAssertLessThanOrEqual(reminders.count, ReminderPlanner.maxPendingNotifications)
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
        XCTAssertEqual(Set(reminders.map(\.id)).count, reminders.count, "IDs eindeutig")
        XCTAssertTrue(reminders.contains { $0.kind == .water && DayKey($0.fireDate, calendar: calendar) == today })
        XCTAssertTrue(reminders.contains { $0.kind == .meal })
        XCTAssertTrue(reminders.contains { $0.kind == .shopping })
        XCTAssertTrue(reminders.contains { $0.kind == .comeBack })

        // Ziel erreicht → heute keine Wasser-Erinnerungen mehr
        var full = WaterLog()
        _ = full.add(3000, at: now.addingTimeInterval(-60))
        let after = planner.plan(input(full))
        XCTAssertFalse(after.contains { $0.kind == .water && DayKey($0.fireDate, calendar: calendar) == today })

        // Rückstand + penetrant → engere Taktung heute
        var behindLog = WaterLog()
        _ = behindLog.add(0, at: now)
        let late = today.date(hour: 15, minute: 0, calendar: calendar)
        var lateInput = input(behindLog)
        lateInput.now = late
        let todaysWater = planner.plan(lateInput).filter { $0.kind == .water && DayKey($0.fireDate, calendar: calendar) == today }
        XCTAssertGreaterThanOrEqual(todaysWater.count, 12)
        XCTAssertTrue(todaysWater[0].body.contains("hinter deinem Plan"))
    }

    func testDisabledRemindersProduceNothing() {
        var settings = ReminderSettings()
        settings.isEnabled = false
        let planner = ReminderPlanner(catalog: catalog, calendar: calendar)
        let result = planner.plan(.init(now: Date(), settings: settings, waterGoalMl: 3000, waterLog: WaterLog(), dayPlans: [],
                                        dailyLimit: 1800, nextUnshoppedDay: nil, openShoppingItems: 0, lastWeighIn: nil))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Persistenz & Sync

    func testAppDataRoundTripAndMerge() throws {
        var local = makeData()
        local.ensurePlanned(today: today, catalog: catalog, calendar: calendar, seed: 1)
        local.stores = [Supermarket(id: "x", name: "EDEKA", address: "Hauptstr. 1", latitude: 1, longitude: 2)]
        _ = local.water.add(500, at: Date(timeIntervalSince1970: 1_000))
        local.touch(Date(timeIntervalSince1970: 2_000))

        let data = try AppData.encoder.encode(local)
        let decoded = try AppData.decoder.decode(AppData.self, from: data)
        XCTAssertEqual(decoded, local)

        var remote = decoded
        _ = remote.water.add(250, at: Date(timeIntervalSince1970: 1_500))
        remote.waterGoalMl = 3500
        remote.touch(Date(timeIntervalSince1970: 3_000))
        _ = local.water.add(300, at: Date(timeIntervalSince1970: 1_600))

        let merged = local.merged(with: remote)
        XCTAssertEqual(merged.waterGoalMl, 3500, "neuerer Stand gewinnt")
        XCTAssertEqual(merged.water.entries.count, 3, "Wasser beider Geräte bleibt erhalten")
    }

    func testFormatting() {
        XCTAssertEqual(Format.amount(1500, unit: .gram), "1,5 kg")
        XCTAssertEqual(Format.amount(250, unit: .milliliter), "250 ml")
        XCTAssertEqual(Format.amount(0.5, unit: .piece), "0,5 Stk.")
        XCTAssertEqual(Format.liters(2250), "2,25 l")
        XCTAssertEqual(Format.packages(2, size: 400, unit: .gram), "2 × 400 g")
    }
}
