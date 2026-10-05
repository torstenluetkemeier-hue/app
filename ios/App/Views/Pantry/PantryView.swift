import SwiftUI
import WochenleichtCore

/// Vorrat: was nach dem Einkauf da sein sollte und was nach den geplanten Mahlzeiten übrig bleibt.
struct PantryView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PantryProjection?
    @State private var showsAdd = false
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Alles"
        case staples = "Gewürze & Basics"
        case fresh = "Frisches"
        var id: String { rawValue }
    }

    var body: some View {
        let rows = model.data.pantryProjection(today: model.today, catalog: model.catalog).filter { row in
            switch filter {
            case .all: true
            case .staples: row.ingredient.isStaple
            case .fresh: (row.ingredient.shelfLifeDays ?? 999) < 30
            }
        }
        let grouped = Dictionary(grouping: rows) { $0.ingredient.category }
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("„Soll“ ist, was laut Einkäufen und gegessenen Mahlzeiten da sein sollte. „Nach Plan“ zeigt, was übrig bleibt, wenn du alle bereits eingekauften Gerichte kochst. Tippe auf einen Artikel, um den Bestand zu korrigieren.")
            }

            let expiring = rows.filter { row in
                guard let date = row.expiresOn, row.quantity > 0 else { return false }
                return date <= model.today.adding(days: 2)
            }
            if !expiring.isEmpty {
                Section("Bald verbrauchen") {
                    ForEach(expiring) { row in
                        Label("\(row.ingredient.name) – bis \(row.expiresOn!.shortTitle)", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if rows.isEmpty {
                ContentUnavailableView("Vorrat leer", systemImage: "cabinet",
                                       description: Text("Nach deinem ersten Einkauf siehst du hier, was du zu Hause haben solltest."))
            }

            ForEach(grouped.keys.sorted { $0.aisleOrder < $1.aisleOrder }) { category in
                Section(category.displayName) {
                    ForEach(grouped[category] ?? []) { row in
                        Button { editing = row } label: { PantryRow(row: row) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Leer", role: .destructive) {
                                    model.setPantryQuantity(0, ingredientId: row.ingredient.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Vorrat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsAdd = true } label: { Label("Hinzufügen", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { row in
            PantryEditSheet(ingredient: row.ingredient, initialQuantity: row.quantity)
        }
        .sheet(isPresented: $showsAdd) {
            PantryAddSheet()
        }
    }
}

private struct PantryRow: View {
    let row: PantryProjection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ingredient.name)
                if row.reserved > 0 {
                    Text("Nach Plan: \(row.isShort ? "es fehlen " : "")\(row.ingredient.formatted(abs(row.remainingAfterPlan)))\(row.isShort ? "" : " übrig")")
                        .font(.caption)
                        .foregroundStyle(row.isShort ? .red : .secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.quantity > 0 ? row.ingredient.formatted(row.quantity) : "leer")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(row.quantity > 0 ? .primary : .secondary)
                Text("Soll").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PantryEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ingredient: Ingredient
    @State private var quantity: Double

    init(ingredient: Ingredient, initialQuantity: Double) {
        self.ingredient = ingredient
        _quantity = State(initialValue: initialQuantity)
    }

    private var step: Double {
        switch ingredient.unit {
        case .piece: 0.5
        case .gram, .milliliter: ingredient.packageSize >= 400 ? 50 : 5
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(ingredient.formatted(quantity), value: $quantity, in: 0...(ingredient.packageSize * 10), step: step)
                    Button("Volle Packung (\(ingredient.formatted(ingredient.packageSize)))") { quantity = ingredient.packageSize }
                    Button("Leer", role: .destructive) { quantity = 0 }
                } footer: {
                    Text("Inventur: Trage ein, wie viel tatsächlich da ist. Die nächste Einkaufsliste berücksichtigt das automatisch.")
                }
            }
            .navigationTitle(ingredient.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        model.setPantryQuantity(quantity, ingredientId: ingredient.id)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PantryAddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: Ingredient?

    var body: some View {
        NavigationStack {
            List {
                let matches = model.catalog.ingredients.values
                    .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    .sorted { $0.name < $1.name }
                ForEach(matches) { ingredient in
                    Button {
                        selected = ingredient
                    } label: {
                        HStack {
                            Text(ingredient.name).foregroundStyle(.primary)
                            Spacer()
                            Text(ingredient.formatted(model.data.pantry.quantity(of: ingredient.id)))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Zutat suchen")
            .navigationTitle("Zum Vorrat hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
            }
            .sheet(item: $selected) { ingredient in
                PantryEditSheet(ingredient: ingredient, initialQuantity: max(model.data.pantry.quantity(of: ingredient.id), ingredient.packageSize))
            }
        }
    }
}
