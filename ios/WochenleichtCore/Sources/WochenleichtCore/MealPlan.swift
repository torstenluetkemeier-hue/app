import Foundation

public struct PlannedMeal: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var mealType: MealType
    public var recipeId: String
    /// Portionsfaktor (0,5 … 1,5 in 0,25er-Schritten), um die Kalorienobergrenze zu treffen.
    public var servings: Double
    public var isEaten: Bool

    public init(id: UUID = UUID(), mealType: MealType, recipeId: String, servings: Double = 1, isEaten: Bool = false) {
        self.id = id
        self.mealType = mealType
        self.recipeId = recipeId
        self.servings = servings
        self.isEaten = isEaten
    }
}

public struct DayPlan: Codable, Hashable, Identifiable, Sendable {
    public var day: DayKey
    public var meals: [PlannedMeal]
    /// true, sobald ein abgeschlossener Einkauf diesen Tag abgedeckt hat.
    public var isShopped: Bool

    public var id: DayKey { day }

    public init(day: DayKey, meals: [PlannedMeal], isShopped: Bool = false) {
        self.day = day
        self.meals = meals
        self.isShopped = isShopped
    }

    public func totalKcal(in catalog: RecipeCatalog) -> Double {
        meals.reduce(0) { $0 + catalog.kcal(ofRecipeId: $1.recipeId) * $1.servings }
    }

    public func eatenKcal(in catalog: RecipeCatalog) -> Double {
        meals.filter(\.isEaten).reduce(0) { $0 + catalog.kcal(ofRecipeId: $1.recipeId) * $1.servings }
    }
}

/// Deterministischer Zufallsgenerator (SplitMix64) – gleiche Eingaben erzeugen gleiche Pläne.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct MealPlanner: Sendable {
    public static let servingStep = 0.25
    public static let minServings = 0.5
    public static let maxServings = 1.5
    /// Pläne sollen die Obergrenze nicht überschreiten, aber auch nicht zu weit darunter liegen.
    public static let minimumFillRatio = 0.85

    public let catalog: RecipeCatalog
    public var dislikedRecipeIds: Set<String>

    public init(catalog: RecipeCatalog, dislikedRecipeIds: Set<String> = []) {
        self.catalog = catalog
        self.dislikedRecipeIds = dislikedRecipeIds
    }

    public struct Context: Sendable {
        /// Rezepte der vorherigen Tage (neueste zuletzt) – vermeidet Wiederholungen.
        public var recentRecipeIds: [String]
        /// Zutaten, die bereits vorrätig oder für die Woche eingeplant sind – deren Verwendung wird bevorzugt (weniger Reste).
        public var preferredIngredientIds: Set<String>

        public init(recentRecipeIds: [String] = [], preferredIngredientIds: Set<String> = []) {
            self.recentRecipeIds = recentRecipeIds
            self.preferredIngredientIds = preferredIngredientIds
        }
    }

    public static func roundServings(_ value: Double) -> Double {
        let stepped = (value / servingStep).rounded() * servingStep
        return min(max(stepped, minServings), maxServings)
    }

    /// Bewertete Vorschläge für eine Mahlzeit mit gegebenem Kalorienbudget (beste zuerst).
    public func rankedCandidates(for mealType: MealType, budget: Double, context: Context,
                                 using rng: inout SeededGenerator, jitter: Double = 0.08) -> [(recipe: Recipe, servings: Double, score: Double)] {
        let recentWindow = Array(context.recentRecipeIds.suffix(8))
        return catalog.recipes(for: mealType)
            .filter { !dislikedRecipeIds.contains($0.id) }
            .map { recipe -> (Recipe, Double, Double) in
                let kcal = max(catalog.kcal(of: recipe), 1)
                let servings = Self.roundServings(budget / kcal)
                let deviation = abs(kcal * servings - budget) / max(budget, 1)
                let repeats = recentWindow.filter { $0 == recipe.id }.count
                let recentPenalty = recentWindow.suffix(4).contains(recipe.id) ? 0.6 : 0
                let freshIngredients = recipe.ingredients.filter { catalog.ingredient($0.ingredientId)?.isStaple == false }
                let overlap = freshIngredients.isEmpty ? 0 : Double(freshIngredients.filter { context.preferredIngredientIds.contains($0.ingredientId) }.count) / Double(freshIngredients.count)
                let noise = Double.random(in: 0..<max(jitter, 0.0001), using: &rng)
                let score = deviation + Double(repeats) * 0.35 + recentPenalty - overlap * 0.2 + noise
                return (recipe, servings, score)
            }
            .sorted { $0.2 < $1.2 }
            .map { (recipe: $0.0, servings: $0.1, score: $0.2) }
    }

    /// Plant einen Tag, sodass die Summe die Obergrenze nicht überschreitet.
    public func planDay(_ day: DayKey, limit: Int, mealTypes: [MealType], context: Context,
                        using rng: inout SeededGenerator) -> DayPlan {
        let includeSnack = mealTypes.contains(.snack)
        var context = context
        var meals: [PlannedMeal] = []
        for mealType in mealTypes {
            let budget = Double(limit) * CalorieCalculator.share(of: mealType, includeSnack: includeSnack)
            guard let best = rankedCandidates(for: mealType, budget: budget, context: context, using: &rng).first else { continue }
            meals.append(PlannedMeal(mealType: mealType, recipeId: best.recipe.id, servings: best.servings))
            context.recentRecipeIds.append(best.recipe.id)
            for item in best.recipe.ingredients { context.preferredIngredientIds.insert(item.ingredientId) }
        }
        var plan = DayPlan(day: day, meals: meals)
        balance(&plan, limit: limit)
        return plan
    }

    /// Passt Portionsgrößen an, bis der Tag unter der Obergrenze und möglichst nah daran liegt.
    public func balance(_ plan: inout DayPlan, limit: Int) {
        let limit = Double(limit)
        func kcal(_ meal: PlannedMeal) -> Double { catalog.kcal(ofRecipeId: meal.recipeId) }

        // Zu viel: größte (noch reduzierbare, nicht gegessene) Mahlzeit verkleinern.
        while plan.totalKcal(in: catalog) > limit {
            let candidates = plan.meals.indices.filter { !plan.meals[$0].isEaten && plan.meals[$0].servings - Self.servingStep >= Self.minServings - 0.0001 }
            guard let index = candidates.max(by: { kcal(plan.meals[$0]) * plan.meals[$0].servings < kcal(plan.meals[$1]) * plan.meals[$1].servings }) else { break }
            plan.meals[index].servings -= Self.servingStep
        }
        // Zu wenig: kleinste Erhöhung wählen, die noch unter der Grenze bleibt.
        while plan.totalKcal(in: catalog) < limit * Self.minimumFillRatio {
            let total = plan.totalKcal(in: catalog)
            let candidates = plan.meals.indices.filter {
                !plan.meals[$0].isEaten
                    && plan.meals[$0].servings + Self.servingStep <= Self.maxServings + 0.0001
                    && total + kcal(plan.meals[$0]) * Self.servingStep <= limit
            }
            guard let index = candidates.min(by: { kcal(plan.meals[$0]) < kcal(plan.meals[$1]) }) else { break }
            plan.meals[index].servings += Self.servingStep
        }
    }

    /// Plant mehrere aufeinanderfolgende Tage.
    public func planDays(_ days: [DayKey], limit: Int, mealTypes: [MealType], context: Context, seed: UInt64) -> [DayPlan] {
        var rng = SeededGenerator(seed: seed)
        var context = context
        var plans: [DayPlan] = []
        for day in days {
            let plan = planDay(day, limit: limit, mealTypes: mealTypes, context: context, using: &rng)
            context.recentRecipeIds.append(contentsOf: plan.meals.map(\.recipeId))
            for meal in plan.meals {
                for item in catalog.recipe(meal.recipeId)?.ingredients ?? [] {
                    context.preferredIngredientIds.insert(item.ingredientId)
                }
            }
            plans.append(plan)
        }
        return plans
    }

    /// Alternativen für eine geplante Mahlzeit, passend zum verbleibenden Tagesbudget.
    public func alternatives(for meal: PlannedMeal, in plan: DayPlan, limit: Int, context: Context, count: Int = 8) -> [(recipe: Recipe, servings: Double)] {
        let othersKcal = plan.meals.filter { $0.id != meal.id }.reduce(0) { $0 + catalog.kcal(ofRecipeId: $1.recipeId) * $1.servings }
        let budget = max(Double(limit) - othersKcal, 100)
        var rng = SeededGenerator(seed: 1)
        return rankedCandidates(for: meal.mealType, budget: budget, context: context, using: &rng, jitter: 0)
            .filter { $0.recipe.id != meal.recipeId }
            .map { candidate in
                // Nie über das Budget hinaus.
                var servings = candidate.servings
                let kcal = catalog.kcal(of: candidate.recipe)
                while servings - Self.servingStep >= Self.minServings - 0.0001 && kcal * servings > budget {
                    servings -= Self.servingStep
                }
                return (recipe: candidate.recipe, servings: servings)
            }
            .prefix(count)
            .map { $0 }
    }
}
