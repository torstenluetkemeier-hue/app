import SwiftUI
import WochenleichtCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedMeal: PlannedMeal?

    var body: some View {
        List {
            if let banner = nagBanner {
                Section {
                    Label(banner, systemImage: "exclamationmark.bubble.fill")
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.semibold))
                        .listRowBackground(Color.red.opacity(0.85))
                }
            }

            Section {
                WaterCard()
            }

            Section {
                CalorieSummary()
            }

            Section("Deine Mahlzeiten heute") {
                if let plan = model.todayPlan {
                    ForEach(plan.meals) { meal in
                        Button { selectedMeal = meal } label: { MealRow(day: plan.day, meal: meal) }
                            .buttonStyle(.plain)
                    }
                } else {
                    Text("Noch kein Plan für heute.")
                }
            }

            if let list = model.data.shoppingList, list.openItemCount > 0 {
                Section {
                    NavigationLink {
                        ShoppingView()
                    } label: {
                        Label("\(list.openItemCount) Artikel für \(list.days.count) Tag(e) einkaufen", systemImage: "cart.badge.plus")
                    }
                }
            }
        }
        .navigationTitle("Heute")
        .sheet(item: $selectedMeal) { meal in
            NavigationStack {
                if let recipe = model.recipe(for: meal) {
                    RecipeDetailView(recipe: recipe, servings: meal.servings, plannedMeal: meal, day: model.today)
                }
            }
        }
        .refreshable { await model.syncNow() }
    }

    /// Penetranter Hinweis, wenn der Nutzer hinterherhinkt.
    private var nagBanner: String? {
        let missing = model.expectedWaterNow - model.waterToday
        if missing >= 500 {
            return "Du liegst \(Format.liters(missing)) hinter deinem Trinkplan. Jetzt sofort ein großes Glas Wasser!"
        }
        if let next = model.data.nextUnshoppedDay(from: model.today), next <= model.today.adding(days: 1),
           (model.data.shoppingList?.openItemCount ?? 0) > 0 {
            return next == model.today ? "Für heute ist noch nicht eingekauft!" : "Morgen fehlen Zutaten – heute noch einkaufen."
        }
        return nil
    }
}

struct WaterCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsCustom = false
    @State private var customAmount = 330

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                ZStack {
                    ProgressRing(progress: Double(model.waterToday) / Double(model.waterGoal), color: .blue)
                    VStack(spacing: 0) {
                        Image(systemName: "drop.fill").foregroundStyle(.blue)
                        Text(Format.liters(model.waterToday))
                            .font(.headline.monospacedDigit())
                        Text("von \(Format.liters(model.waterGoal))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 110, height: 110)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Wasser").font(.title3.bold())
                    let remaining = max(model.waterGoal - model.waterToday, 0)
                    if remaining == 0 {
                        Label("Tagesziel erreicht!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Text("Noch \(Format.liters(remaining))")
                        Text("Plan bis jetzt: \(Format.liters(model.expectedWaterNow))")
                            .font(.caption)
                            .foregroundStyle(model.waterToday >= model.expectedWaterNow ? Color.secondary : Color.red)
                    }
                    let streak = model.data.water.streak(goal: model.waterGoal, today: model.today)
                    if streak > 0 {
                        Label("\(streak) Tag(e) in Folge", systemImage: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                ForEach([250, 500, 750], id: \.self) { amount in
                    Button {
                        model.logWater(amount)
                    } label: {
                        Text("+\(amount) ml").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
                Button {
                    showsCustom = true
                } label: {
                    Image(systemName: "plus").frame(maxWidth: 30)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .accessibilityLabel("Eigene Menge")
            }

            if let last = model.data.water.entries(on: model.today).last {
                HStack {
                    Text("Zuletzt: \(last.milliliters) ml um \(last.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rückgängig") { model.removeWater(last.id) }
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showsCustom) {
            NavigationStack {
                Form {
                    Stepper("\(customAmount) ml", value: $customAmount, in: 50...2000, step: 50)
                }
                .navigationTitle("Eigene Menge")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { showsCustom = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Eintragen") {
                            model.logWater(customAmount)
                            showsCustom = false
                        }
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }
}

struct CalorieSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = model.todayPlan
        let eaten = plan?.eatenKcal(in: model.catalog) ?? 0
        let planned = plan?.totalKcal(in: model.catalog) ?? 0
        let limit = Double(model.dailyLimit)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kalorien").font(.title3.bold())
                Spacer()
                Text("Limit \(model.dailyLimit) kcal").font(.subheadline).foregroundStyle(.secondary)
            }
            ProgressView(value: min(eaten, limit), total: limit)
                .tint(eaten > limit ? .red : .orange)
            HStack {
                Text("Gegessen: \(Format.kcal(eaten))")
                Spacer()
                Text("Geplant: \(Format.kcal(planned))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
