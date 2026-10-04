import Foundation

public struct Supermarket: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var latitude: Double
    public var longitude: Double

    public init(id: String, name: String, address: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Erkennt bekannte Handelsketten anhand des Namens.
    public var chain: String? {
        let lower = name.lowercased()
        let chains = ["aldi", "lidl", "rewe", "edeka", "kaufland", "penny", "netto", "norma", "globus", "real", "tegut", "denns", "alnatura", "dm", "rossmann", "marktkauf", "hit", "famila", "combi", "nahkauf"]
        return chains.first { chain in
            lower.split(whereSeparator: { !$0.isLetter }).contains { $0 == Substring(chain) }
        }.map { $0.uppercased() == "DM" ? "dm" : $0.capitalized }
    }

    public func distance(toLatitude lat: Double, longitude lon: Double) -> Double {
        // Haversine, Ergebnis in Metern
        let r = 6_371_000.0
        let dLat = (lat - latitude) * .pi / 180
        let dLon = (lon - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * .pi / 180) * cos(lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Welche Zutat in welchem Supermarkt gekauft wird.
public struct StoreAssignment: Codable, Hashable, Sendable {
    public var defaultStoreId: String?
    /// Kategorie (rawValue) → Supermarkt-ID
    public var categoryStores: [String: String]
    /// Zutat-ID → Supermarkt-ID (hat Vorrang vor der Kategorie)
    public var ingredientStores: [String: String]

    public init(defaultStoreId: String? = nil, categoryStores: [String: String] = [:], ingredientStores: [String: String] = [:]) {
        self.defaultStoreId = defaultStoreId
        self.categoryStores = categoryStores
        self.ingredientStores = ingredientStores
    }

    public func storeId(for ingredient: Ingredient) -> String? {
        ingredientStores[ingredient.id] ?? categoryStores[ingredient.category.rawValue] ?? defaultStoreId
    }

    /// Entfernt Verweise auf nicht mehr vorhandene Märkte.
    public mutating func prune(validStoreIds: Set<String>) {
        if let id = defaultStoreId, !validStoreIds.contains(id) { defaultStoreId = validStoreIds.sorted().first }
        categoryStores = categoryStores.filter { validStoreIds.contains($0.value) }
        ingredientStores = ingredientStores.filter { validStoreIds.contains($0.value) }
    }
}

public struct ShoppingItem: Codable, Hashable, Identifiable, Sendable {
    public var ingredientId: String
    /// Für den Plan fehlende Menge.
    public var neededAmount: Double
    /// Anzahl Packungen, die gekauft werden.
    public var packages: Int
    /// Gekaufte Menge (Packungen × Packungsgröße) – geht nach dem Einkauf in den Vorrat.
    public var purchaseAmount: Double
    public var isChecked: Bool

    public var id: String { ingredientId }

    /// Was nach dem Kochen der geplanten Gerichte übrig bleibt.
    public var leftoverAmount: Double { max(0, purchaseAmount - neededAmount) }
}

public struct ShoppingList: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var days: [DayKey]
    public var items: [ShoppingItem]
    public var createdAt: Date

    public init(id: UUID = UUID(), days: [DayKey], items: [ShoppingItem], createdAt: Date = Date()) {
        self.id = id
        self.days = days
        self.items = items
        self.createdAt = createdAt
    }

    public var openItemCount: Int { items.filter { !$0.isChecked }.count }

    public struct Section: Identifiable, Hashable, Sendable {
        public let category: IngredientCategory
        public let items: [ShoppingItem]
        public var id: IngredientCategory { category }
    }

    public struct StoreGroup: Identifiable, Hashable, Sendable {
        /// nil = noch keinem Supermarkt zugeordnet
        public let store: Supermarket?
        public let sections: [Section]
        public var id: String { store?.id ?? "_unassigned" }
        public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
        public var openItemCount: Int { sections.reduce(0) { $0 + $1.items.filter { !$0.isChecked }.count } }
    }

    /// Einkaufslisten je Supermarkt, innerhalb nach Gang (Kategorie) sortiert.
    public func grouped(stores: [Supermarket], assignment: StoreAssignment, catalog: RecipeCatalog) -> [StoreGroup] {
        let storeById = Dictionary(stores.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String?: [ShoppingItem]] = [:]
        for item in items {
            guard let ingredient = catalog.ingredient(item.ingredientId) else { continue }
            let storeId = assignment.storeId(for: ingredient).flatMap { storeById[$0] != nil ? $0 : nil }
            buckets[storeId, default: []].append(item)
        }
        return buckets.map { storeId, items -> StoreGroup in
            let byCategory = Dictionary(grouping: items) { catalog.ingredient($0.ingredientId)?.category ?? .other }
            let sections = byCategory.keys.sorted { $0.aisleOrder < $1.aisleOrder }.map { category in
                Section(category: category, items: byCategory[category]!.sorted {
                    (catalog.ingredient($0.ingredientId)?.name ?? "") < (catalog.ingredient($1.ingredientId)?.name ?? "")
                })
            }
            return StoreGroup(store: storeId.flatMap { storeById[$0] }, sections: sections)
        }
        .sorted { lhs, rhs in
            switch (lhs.store, rhs.store) {
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?): return l.name < r.name
            }
        }
    }
}

public enum ShoppingListBuilder {
    /// Erstellt die Einkaufsliste für `targetDays`.
    /// - Parameters:
    ///   - reservations: Zutaten, die bereits für andere (schon eingekaufte) Tage eingeplant sind und daher nicht verfügbar sind.
    ///   - previous: bestehende Liste, deren Abhak-Status erhalten bleibt.
    public static func build(targetDays: [DayPlan], pantry: Pantry, reservations: [String: Double],
                             catalog: RecipeCatalog, previous: ShoppingList? = nil, now: Date = Date()) -> ShoppingList {
        let meals = targetDays.flatMap { $0.meals.filter { !$0.isEaten } }
        let required = IngredientMath.requirements(for: meals, catalog: catalog)
        let previousById = Dictionary((previous?.items ?? []).map { ($0.ingredientId, $0) }, uniquingKeysWith: { first, _ in first })

        var items: [ShoppingItem] = []
        for (ingredientId, amount) in required {
            guard let ingredient = catalog.ingredient(ingredientId) else { continue }
            let available = max(0, pantry.quantity(of: ingredientId) - (reservations[ingredientId] ?? 0))
            let missing = amount - available
            guard missing > 0.0001 else { continue }
            let packages = max(1, Int((missing / ingredient.packageSize - 1e-9).rounded(.up)))
            items.append(ShoppingItem(
                ingredientId: ingredientId,
                neededAmount: missing,
                packages: packages,
                purchaseAmount: Double(packages) * ingredient.packageSize,
                isChecked: previousById[ingredientId]?.isChecked ?? false
            ))
        }
        items.sort { $0.ingredientId < $1.ingredientId }
        let days = targetDays.map(\.day).sorted()
        let sameDays = previous?.days == days
        return ShoppingList(id: sameDays ? previous!.id : UUID(), days: days, items: items,
                            createdAt: sameDays ? previous!.createdAt : now)
    }
}
