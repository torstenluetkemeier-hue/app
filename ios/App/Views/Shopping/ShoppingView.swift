import SwiftUI
import WochenleichtCore

/// Einkaufslisten pro Supermarkt.
struct ShoppingView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGroupId: String?
    @State private var confirmComplete = false

    private var groups: [ShoppingList.StoreGroup] {
        model.data.shoppingList?.grouped(stores: model.data.stores, assignment: model.data.storeAssignment, catalog: model.catalog) ?? []
    }

    var body: some View {
        let groups = groups
        let selected = groups.first { $0.id == selectedGroupId } ?? groups.first
        List {
            if model.data.stores.isEmpty {
                Section {
                    NavigationLink {
                        StoresView()
                    } label: {
                        Label("Supermärkte in deiner Nähe finden", systemImage: "location.magnifyingglass")
                            .font(.headline)
                    }
                } footer: {
                    Text("Wähle deine Märkte – dann bekommst du für jeden Markt eine eigene Liste und eine Erinnerung, wenn du dort bist.")
                }
            }

            if let list = model.data.shoppingList, !list.items.isEmpty {
                Section {
                    LabeledContent("Für", value: daysDescription(list.days))
                    LabeledContent("Offen", value: "\(list.openItemCount) von \(list.items.count) Artikeln")
                }

                if groups.count > 1 {
                    Section {
                        Picker("Supermarkt", selection: Binding(
                            get: { selected?.id ?? "" },
                            set: { selectedGroupId = $0 }
                        )) {
                            ForEach(groups) { group in
                                Text("\(group.store?.name ?? "Ohne Markt") (\(group.openItemCount))").tag(group.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if let selected {
                    ForEach(selected.sections) { section in
                        Section(section.category.displayName) {
                            ForEach(section.items) { item in
                                ShoppingItemRow(item: item, currentStoreId: selected.store?.id)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        confirmComplete = true
                    } label: {
                        Label("Einkauf abschließen", systemImage: "checkmark.seal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            } else {
                ContentUnavailableView(
                    "Alles eingekauft",
                    systemImage: "cart.fill.badge.checkmark",
                    description: Text("Für die geplanten Tage ist alles im Vorrat. Sobald neue Tage geplant werden, erscheint hier die nächste Liste.")
                )
            }
        }
        .navigationTitle(selected?.store?.name ?? "Einkaufsliste")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let selected {
                    ShareLink(item: shareText(for: selected)) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                }
                NavigationLink {
                    StoresView()
                } label: {
                    Label("Supermärkte", systemImage: "storefront")
                }
            }
        }
        .confirmationDialog("Einkauf abschließen?", isPresented: $confirmComplete, titleVisibility: .visible) {
            Button("Abschließen") { model.completeShopping() }
        } message: {
            let checked = model.data.shoppingList?.items.filter(\.isChecked).count ?? 0
            Text("\(checked) abgehakte Artikel werden in deinen Vorrat übernommen. Nicht abgehakte Artikel gelten als nicht gekauft.")
        }
    }

    private func daysDescription(_ days: [DayKey]) -> String {
        guard let first = days.first, let last = days.last else { return "–" }
        return first == last ? first.shortTitle : "\(first.shortTitle) – \(last.shortTitle) (\(days.count) Tage)"
    }

    private func shareText(for group: ShoppingList.StoreGroup) -> String {
        var lines = ["🛒 Einkaufsliste \(group.store?.name ?? "")"]
        for section in group.sections {
            lines.append("")
            lines.append(section.category.displayName)
            for item in section.items {
                guard let ingredient = model.catalog.ingredient(item.ingredientId) else { continue }
                lines.append("\(item.isChecked ? "☑︎" : "☐") \(ingredient.name) – \(Format.packages(item.packages, size: ingredient.packageSize, unit: ingredient.unit))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct ShoppingItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ShoppingItem
    let currentStoreId: String?

    var body: some View {
        if let ingredient = model.catalog.ingredient(item.ingredientId) {
            Button {
                model.setChecked(!item.isChecked, ingredientId: item.ingredientId)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.isChecked ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ingredient.name)
                            .strikethrough(item.isChecked)
                            .foregroundStyle(item.isChecked ? .secondary : .primary)
                        Text("benötigt \(ingredient.formatted(item.neededAmount))" + (item.leftoverAmount > 0.5 ? " · Rest für Vorrat: \(ingredient.formatted(item.leftoverAmount))" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.packages(item.packages, size: ingredient.packageSize, unit: ingredient.unit))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !model.data.stores.isEmpty {
                    Section("Kaufen bei …") {
                        ForEach(model.data.stores.filter { $0.id != currentStoreId }) { store in
                            Button(store.name) { model.assign(ingredientId: ingredient.id, to: store.id) }
                        }
                    }
                    Section("Ganze Kategorie „\(ingredient.category.displayName)“ kaufen bei …") {
                        ForEach(model.data.stores) { store in
                            Button(store.name) { model.assign(category: ingredient.category, to: store.id) }
                        }
                    }
                }
            }
        }
    }
}
