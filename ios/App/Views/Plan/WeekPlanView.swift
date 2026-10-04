import SwiftUI
import WochenleichtCore

/// Rollierender Wochenplan – immer mindestens 7 Tage im Voraus.
struct WeekPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: Tageskarten im Raster
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        ForEach(model.upcomingPlans) { plan in
                            NavigationLink(value: plan.day) {
                                DayCard(plan: plan)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            } else {
                List {
                    ForEach(model.upcomingPlans) { plan in
                        Section {
                            NavigationLink(value: plan.day) {
                                DaySummaryRow(plan: plan)
                            }
                        } header: {
                            Text(plan.day.title(today: model.today))
                        }
                    }
                }
            }
        }
        .navigationTitle("Wochenplan")
        .navigationDestination(for: DayKey.self) { day in
            DayDetailView(day: day)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    RecipeBrowserView()
                } label: {
                    Label("Rezepte", systemImage: "book")
                }
            }
        }
    }
}

private struct DaySummaryRow: View {
    @Environment(AppModel.self) private var model
    let plan: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.meals) { meal in
                HStack {
                    Image(systemName: meal.isEaten ? "checkmark.circle.fill" : meal.mealType.symbolName)
                        .foregroundStyle(meal.isEaten ? .green : .secondary)
                        .frame(width: 22)
                    Text(model.recipe(for: meal)?.name ?? "–")
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(model.kcal(for: meal)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if plan.isShopped {
                    Label("Eingekauft", systemImage: "cart.fill.badge.checkmark").foregroundStyle(.green)
                } else {
                    Label("Noch einkaufen", systemImage: "cart").foregroundStyle(.orange)
                }
                Spacer()
                Text("\(Format.kcal(plan.totalKcal(in: model.catalog))) / \(model.dailyLimit)")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct DayCard: View {
    @Environment(AppModel.self) private var model
    let plan: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.day.title(today: model.today)).font(.headline)
            DaySummaryRow(plan: plan)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    let day: DayKey
    @State private var swapping: PlannedMeal?
    @State private var confirmRegenerate = false

    var body: some View {
        List {
            if let plan = model.data.plan(for: day) {
                Section {
                    let total = plan.totalKcal(in: model.catalog)
                    LabeledContent("Geplant", value: "\(Format.kcal(total)) von \(model.dailyLimit) kcal")
                    ProgressView(value: min(total, Double(model.dailyLimit)), total: Double(model.dailyLimit))
                        .tint(total > Double(model.dailyLimit) ? .red : .green)
                }
                ForEach(plan.meals) { meal in
                    Section(meal.mealType.displayName) {
                        if let recipe = model.recipe(for: meal) {
                            NavigationLink {
                                RecipeDetailView(recipe: recipe, servings: meal.servings, plannedMeal: meal, day: day)
                            } label: {
                                MealRow(day: day, meal: meal)
                            }
                            Stepper(Format.servings(meal.servings), value: Binding(
                                get: { meal.servings },
                                set: { model.setServings($0, day: day, mealId: meal.id) }
                            ), in: MealPlanner.minServings...MealPlanner.maxServings, step: MealPlanner.servingStep)
                            .disabled(meal.isEaten)
                            Button {
                                swapping = meal
                            } label: {
                                Label("Anderes Rezept wählen", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(meal.isEaten)
                        }
                    }
                }
                if plan.isShopped {
                    Section {
                        Text("Für diesen Tag wurde bereits eingekauft. Änderungen erzeugen ggf. eine Nachkauf-Liste.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("Kein Plan", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle(day.title(today: model.today))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmRegenerate = true
                } label: {
                    Label("Neu planen", systemImage: "wand.and.stars")
                }
            }
        }
        .confirmationDialog("Tag neu planen?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Neu planen") { model.regenerate(day: day) }
        } message: {
            Text("Alle noch nicht gegessenen Mahlzeiten werden durch neue Vorschläge ersetzt.")
        }
        .sheet(item: $swapping) { meal in
            AlternativesSheet(day: day, meal: meal)
        }
    }
}

/// Alternative Rezepte, die ins verbleibende Tagesbudget passen.
struct AlternativesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: DayKey
    let meal: PlannedMeal

    var body: some View {
        NavigationStack {
            List(model.alternatives(for: meal, on: day), id: \.recipe.id) { option in
                Button {
                    model.replaceMeal(day: day, mealId: meal.id, recipeId: option.recipe.id, servings: option.servings)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.recipe.name).foregroundStyle(.primary)
                            Text("\(Format.servings(option.servings)) · \(option.recipe.minutes) Min.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KcalBadge(kcal: model.catalog.kcal(of: option.recipe) * option.servings)
                    }
                }
            }
            .navigationTitle("Alternativen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
        }
    }
}
