import Foundation

public struct PantryItem: Codable, Hashable, Identifiable, Sendable {
    public var ingredientId: String
    /// Soll-Bestand in der Einheit der Zutat.
    public var quantity: Double
    /// Mindesthaltbarkeit der zuletzt gekauften frischen Ware.
    public var expiresOn: DayKey?

    public var id: String { ingredientId }

    public init(ingredientId: String, quantity: Double, expiresOn: DayKey? = nil) {
        self.ingredientId = ingredientId
        self.quantity = quantity
        self.expiresOn = expiresOn
    }
}

/// Bestand, der nach Einkäufen vorhanden sein sollte und durch gegessene Mahlzeiten sinkt.
public struct Pantry: Codable, Hashable, Sendable {
    public private(set) var items: [String: PantryItem]

    public init(items: [PantryItem] = []) {
        self.items = Dictionary(items.map { ($0.ingredientId, $0) }, uniquingKeysWith: { $1 })
    }

    public func quantity(of ingredientId: String) -> Double {
        items[ingredientId]?.quantity ?? 0
    }

    public mutating func add(_ ingredient: Ingredient, amount: Double, purchasedOn day: DayKey, calendar: Calendar = .current) {
        guard amount > 0 else { return }
        var item = items[ingredient.id] ?? PantryItem(ingredientId: ingredient.id, quantity: 0)
        item.quantity += amount
        if let shelfLife = ingredient.shelfLifeDays, shelfLife < 365 {
            item.expiresOn = day.adding(days: shelfLife, calendar: calendar)
        }
        items[ingredient.id] = item
    }

    public mutating func consume(_ ingredientId: String, amount: Double) {
        guard var item = items[ingredientId] else { return }
        item.quantity = max(0, item.quantity - amount)
        if item.quantity < 0.0001 {
            items[ingredientId] = nil
        } else {
            items[ingredientId] = item
        }
    }

    /// Inventur: tatsächlichen Bestand setzen (0 entfernt den Artikel).
    public mutating func setQuantity(_ quantity: Double, for ingredientId: String) {
        if quantity <= 0.0001 {
            items[ingredientId] = nil
        } else {
            var item = items[ingredientId] ?? PantryItem(ingredientId: ingredientId, quantity: 0)
            item.quantity = quantity
            items[ingredientId] = item
        }
    }

    public var nonEmptyIngredientIds: Set<String> {
        Set(items.values.filter { $0.quantity > 0 }.map(\.ingredientId))
    }
}

public enum IngredientMath {
    /// Summe der benötigten Zutatenmengen für die übergebenen Mahlzeiten.
    public static func requirements<S: Sequence>(for meals: S, catalog: RecipeCatalog) -> [String: Double] where S.Element == PlannedMeal {
        var result: [String: Double] = [:]
        for meal in meals {
            guard let recipe = catalog.recipe(meal.recipeId) else { continue }
            for item in recipe.ingredients {
                result[item.ingredientId, default: 0] += item.amount * meal.servings
            }
        }
        return result
    }
}

/// Zeile der Vorratsansicht: was da sein sollte und was nach den geplanten Mahlzeiten übrig bleibt.
public struct PantryProjection: Identifiable, Hashable, Sendable {
    public let ingredient: Ingredient
    public let quantity: Double
    public let reserved: Double
    public let expiresOn: DayKey?

    public var id: String { ingredient.id }
    public var remainingAfterPlan: Double { quantity - reserved }
    public var isShort: Bool { remainingAfterPlan < -0.0001 }

    public static func build(pantry: Pantry, reservations: [String: Double], catalog: RecipeCatalog) -> [PantryProjection] {
        let ids = Set(pantry.items.keys).union(reservations.keys)
        return ids.compactMap { id in
            guard let ingredient = catalog.ingredient(id) else { return nil }
            return PantryProjection(ingredient: ingredient, quantity: pantry.quantity(of: id),
                                    reserved: reservations[id] ?? 0, expiresOn: pantry.items[id]?.expiresOn)
        }
        .sorted { ($0.ingredient.category.aisleOrder, $0.ingredient.name) < ($1.ingredient.category.aisleOrder, $1.ingredient.name) }
    }
}
