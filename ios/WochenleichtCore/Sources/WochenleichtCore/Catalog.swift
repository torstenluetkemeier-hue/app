import Foundation

public enum IngredientCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case produce, dairy, meatFish, bakery, grains, canned, frozen, nutsSeeds, oilsSauces, spices, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .produce: "Obst & Gemüse"
        case .dairy: "Milchprodukte & Eier"
        case .meatFish: "Fleisch, Fisch & Tofu"
        case .bakery: "Brot & Backwaren"
        case .grains: "Nudeln, Reis & Getreide"
        case .canned: "Konserven & Hülsenfrüchte"
        case .frozen: "Tiefkühl"
        case .nutsSeeds: "Nüsse & Saaten"
        case .oilsSauces: "Öle, Essig & Saucen"
        case .spices: "Gewürze"
        case .other: "Sonstiges"
        }
    }

    /// Typische Laufreihenfolge im Supermarkt – Sortierung der Einkaufsliste.
    public var aisleOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public enum MeasureUnit: String, Codable, Sendable {
    case gram = "g"
    case milliliter = "ml"
    case piece

    /// kcal-Angaben beziehen sich bei g/ml auf 100 Einheiten, bei Stück auf 1 Stück.
    var kcalReferenceAmount: Double { self == .piece ? 1 : 100 }
}

public struct Ingredient: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: IngredientCategory
    public let unit: MeasureUnit
    /// Inhalt einer handelsüblichen Packung in `unit` – die Einkaufsliste rundet darauf auf.
    public let packageSize: Double
    public let kcal: Double
    public let shelfLifeDays: Int?
    /// Vorratsartikel (Gewürze, Öl …): werden nur nachgekauft, wenn sie im Vorrat fehlen.
    public let isStaple: Bool

    public init(id: String, name: String, category: IngredientCategory, unit: MeasureUnit, packageSize: Double,
                kcal: Double, shelfLifeDays: Int? = nil, isStaple: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.unit = unit
        self.packageSize = packageSize
        self.kcal = kcal
        self.shelfLifeDays = shelfLifeDays
        self.isStaple = isStaple
    }

    public func kcal(for amount: Double) -> Double {
        kcal * amount / unit.kcalReferenceAmount
    }
}

public enum MealType: String, Codable, CaseIterable, Sendable, Identifiable {
    case breakfast, lunch, dinner, snack

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .breakfast: "Frühstück"
        case .lunch: "Mittagessen"
        case .dinner: "Abendessen"
        case .snack: "Snack"
        }
    }

    public var symbolName: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "carrot"
        }
    }
}

public struct RecipeIngredient: Codable, Hashable, Sendable {
    public let ingredientId: String
    /// Menge für eine Portion.
    public let amount: Double

    public init(ingredientId: String, amount: Double) {
        self.ingredientId = ingredientId
        self.amount = amount
    }
}

public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let mealType: MealType
    public let minutes: Int
    public let tags: [String]
    public let ingredients: [RecipeIngredient]
    public let steps: [String]

    public init(id: String, name: String, mealType: MealType, minutes: Int, tags: [String] = [],
                ingredients: [RecipeIngredient], steps: [String]) {
        self.id = id
        self.name = name
        self.mealType = mealType
        self.minutes = minutes
        self.tags = tags
        self.ingredients = ingredients
        self.steps = steps
    }
}

public enum CatalogError: Error, Equatable {
    case resourceMissing(String)
    case unknownIngredient(recipe: String, ingredient: String)
}

/// Unveränderliche Rezept- und Zutatendatenbank.
public struct RecipeCatalog: Sendable {
    public let ingredients: [String: Ingredient]
    public let recipes: [Recipe]
    private let recipesById: [String: Recipe]
    private let kcalById: [String: Double]

    public init(ingredients: [Ingredient], recipes: [Recipe]) throws {
        let ingredientMap = Dictionary(ingredients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kcal: [String: Double] = [:]
        for recipe in recipes {
            var total = 0.0
            for item in recipe.ingredients {
                guard let ingredient = ingredientMap[item.ingredientId] else {
                    throw CatalogError.unknownIngredient(recipe: recipe.id, ingredient: item.ingredientId)
                }
                total += ingredient.kcal(for: item.amount)
            }
            kcal[recipe.id] = total
        }
        self.ingredients = ingredientMap
        self.recipes = recipes
        self.recipesById = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.kcalById = kcal
    }

    /// Lädt den mitgelieferten Katalog aus den Paket-Ressourcen.
    public static func bundled() throws -> RecipeCatalog {
        func load<T: Decodable>(_ name: String) throws -> T {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw CatalogError.resourceMissing(name)
            }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        }
        return try RecipeCatalog(ingredients: load("ingredients"), recipes: load("recipes"))
    }

    public func recipe(_ id: String) -> Recipe? { recipesById[id] }
    public func ingredient(_ id: String) -> Ingredient? { ingredients[id] }

    /// kcal pro Portion.
    public func kcal(of recipe: Recipe) -> Double { kcalById[recipe.id] ?? 0 }
    public func kcal(ofRecipeId id: String) -> Double { kcalById[id] ?? 0 }

    public func recipes(for mealType: MealType) -> [Recipe] {
        recipes.filter { $0.mealType == mealType }
    }

    /// Rezeptvorschläge unterhalb einer Kalorienobergrenze, nach Nähe zur Obergrenze sortiert.
    public func suggestions(maxKcal: Double, mealType: MealType? = nil, searchText: String = "") -> [Recipe] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return recipes
            .filter { mealType == nil || $0.mealType == mealType }
            .filter { kcal(of: $0) <= maxKcal }
            .filter { recipe in
                query.isEmpty
                    || recipe.name.lowercased().contains(query)
                    || recipe.tags.contains { $0.lowercased().contains(query) }
                    || recipe.ingredients.contains { ingredients[$0.ingredientId]?.name.lowercased().contains(query) == true }
            }
            .sorted { kcal(of: $0) > kcal(of: $1) }
    }
}
