import SwiftUI
import WochenleichtCore

struct RecipeDetailView: View {
    @Environment(AppModel.self) private var model
    let recipe: Recipe
    var servings: Double = 1
    var plannedMeal: PlannedMeal?
    var day: DayKey?

    private var currentMeal: PlannedMeal? {
        guard let plannedMeal, let day else { return nil }
        return model.data.plan(for: day)?.meals.first { $0.id == plannedMeal.id }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    KcalBadge(kcal: model.catalog.kcal(of: recipe) * servings)
                    Label("\(recipe.minutes) Min.", systemImage: "clock")
                    Label(Format.servings(servings), systemImage: "person")
                }
                .font(.subheadline)
                if !recipe.tags.isEmpty {
                    Text(recipe.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                if let meal = currentMeal, let day {
                    Button {
                        model.setEaten(!meal.isEaten, day: day, mealId: meal.id)
                    } label: {
                        Label(meal.isEaten ? "Als nicht gegessen markieren" : "Gegessen – Zutaten aus Vorrat abbuchen",
                              systemImage: meal.isEaten ? "arrow.uturn.backward" : "checkmark.circle")
                    }
                }
            }

            Section("Zutaten") {
                ForEach(recipe.ingredients, id: \.ingredientId) { item in
                    if let ingredient = model.catalog.ingredient(item.ingredientId) {
                        HStack {
                            Text(ingredient.name)
                            Spacer()
                            Text(ingredient.formatted(item.amount * servings))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section("Zubereitung") {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        Text(step)
                    }
                }
            }

            Section {
                Button(role: model.data.dislikedRecipeIds.contains(recipe.id) ? nil : .destructive) {
                    model.toggleDisliked(recipe.id)
                } label: {
                    if model.data.dislikedRecipeIds.contains(recipe.id) {
                        Label("Wieder vorschlagen", systemImage: "hand.thumbsup")
                    } else {
                        Label("Mag ich nicht – nicht mehr vorschlagen", systemImage: "hand.thumbsdown")
                    }
                }
            }
        }
        .navigationTitle(recipe.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Rezeptvorschläge nach Kalorienobergrenze.
struct RecipeBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var maxKcal: Double = 500
    @State private var mealType: MealType?
    @State private var search = ""

    var body: some View {
        let results = model.catalog.suggestions(maxKcal: maxKcal, mealType: mealType, searchText: search)
        List {
            Section {
                VStack(alignment: .leading) {
                    Text("Höchstens \(Int(maxKcal)) kcal pro Portion").font(.subheadline.weight(.semibold))
                    Slider(value: $maxKcal, in: 100...900, step: 25)
                }
                Picker("Mahlzeit", selection: $mealType) {
                    Text("Alle").tag(MealType?.none)
                    ForEach(MealType.allCases) { Text($0.displayName).tag(MealType?.some($0)) }
                }
            } footer: {
                Text("Dein Tageslimit: \(model.dailyLimit) kcal")
            }

            Section("\(results.count) Rezepte") {
                ForEach(results) { recipe in
                    NavigationLink {
                        RecipeDetailView(recipe: recipe)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recipe.name)
                                    .foregroundStyle(model.data.dislikedRecipeIds.contains(recipe.id) ? .secondary : .primary)
                                Text("\(recipe.mealType.displayName) · \(recipe.minutes) Min.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            KcalBadge(kcal: model.catalog.kcal(of: recipe))
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Rezept oder Zutat")
        .navigationTitle("Rezepte")
        .onAppear {
            if maxKcal == 500 {
                maxKcal = (Double(model.dailyLimit) * 0.35 / 25).rounded() * 25
            }
        }
    }
}
