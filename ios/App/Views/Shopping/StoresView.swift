import CoreLocation
import SwiftUI
import WochenleichtCore

/// Erkennt Supermärkte in der Umgebung und verwaltet die Auswahl.
struct StoresView: View {
    @Environment(AppModel.self) private var model
    @State private var location = LocationService()
    @State private var results: [Supermarket] = []
    @State private var userLocation: CLLocation?
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var selectedIds: Set<String> { Set(model.data.stores.map(\.id)) }

    var body: some View {
        List {
            if !model.data.stores.isEmpty {
                Section {
                    ForEach(model.data.stores) { store in
                        HStack {
                            StoreLabel(store: store, location: userLocation)
                            Spacer()
                            if model.data.storeAssignment.defaultStoreId == store.id {
                                Text("Standard").font(.caption.bold()).foregroundStyle(.tint)
                            }
                        }
                        .swipeActions {
                            Button("Entfernen", role: .destructive) {
                                model.setStores(model.data.stores.filter { $0.id != store.id })
                            }
                            Button("Standard") { model.setDefaultStore(store.id) }.tint(.accentColor)
                        }
                    }
                } header: {
                    Text("Meine Supermärkte")
                } footer: {
                    Text("Nach links wischen, um den Standardmarkt festzulegen oder einen Markt zu entfernen.")
                }

                if model.data.stores.count > 1 {
                    Section {
                        NavigationLink("Was kaufe ich wo?") { StoreAssignmentView() }
                    } footer: {
                        Text("Lege fest, welche Kategorien du in welchem Markt kaufst – z. B. Gewürze im Discounter, Frisches im Supermarkt.")
                    }
                }
            }

            Section {
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Label("In meiner Nähe suchen", systemImage: "location.fill")
                        Spacer()
                        if isSearching { ProgressView() }
                    }
                }
                .disabled(isSearching)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
                ForEach(results) { store in
                    Button {
                        toggle(store)
                    } label: {
                        HStack {
                            StoreLabel(store: store, location: userLocation)
                            Spacer()
                            Image(systemName: selectedIds.contains(store.id) ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(selectedIds.contains(store.id) ? Color.green : Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Supermärkte in der Umgebung")
            } footer: {
                Text("Suche über Apple Karten im Umkreis von 3 km.")
            }
        }
        .navigationTitle("Supermärkte")
        .task {
            if results.isEmpty && model.data.stores.isEmpty { await search() }
        }
    }

    private func toggle(_ store: Supermarket) {
        if selectedIds.contains(store.id) {
            model.setStores(model.data.stores.filter { $0.id != store.id })
        } else {
            model.setStores(model.data.stores + [store])
        }
    }

    private func search() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let current = try await location.currentLocation()
            userLocation = current
            results = try await SupermarketFinder.nearby(current)
            if results.isEmpty { errorMessage = "Keine Supermärkte im Umkreis gefunden." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StoreLabel: View {
    let store: Supermarket
    let location: CLLocation?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront.fill")
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let location {
                        let meters = store.distance(toLatitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                        Text(meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000))
                    }
                    if !store.address.isEmpty { Text(store.address).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch store.chain ?? "" {
        case "Aldi": .blue
        case "Lidl": .yellow
        case "Rewe": .red
        case "Edeka": .indigo
        case "Kaufland": .red
        case "Penny": .red
        case "Netto": .yellow
        default: .green
        }
    }
}

/// Zuordnung von Kategorien zu Supermärkten.
struct StoreAssignmentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("Standardmarkt", selection: Binding(
                    get: { model.data.storeAssignment.defaultStoreId ?? "" },
                    set: { model.setDefaultStore($0) }
                )) {
                    ForEach(model.data.stores) { Text($0.name).tag($0.id) }
                }
            }
            Section("Kategorien") {
                ForEach(IngredientCategory.allCases.filter { $0 != .other }) { category in
                    Picker(category.displayName, selection: Binding(
                        get: { model.data.storeAssignment.categoryStores[category.rawValue] ?? "" },
                        set: { model.assign(category: category, to: $0.isEmpty ? nil : $0) }
                    )) {
                        Text("Standardmarkt").tag("")
                        ForEach(model.data.stores) { Text($0.name).tag($0.id) }
                    }
                }
            }
        }
        .navigationTitle("Was kaufe ich wo?")
    }
}
