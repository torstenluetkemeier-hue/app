import SwiftUI
import WochenleichtCore

/// Fortschrittsring (Wasser, Kalorien).
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 14
    var color: Color = .blue

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring, value: progress)
        }
    }
}

struct KcalBadge: View {
    let kcal: Double

    var body: some View {
        Text(Format.kcal(kcal))
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// Zeile einer geplanten Mahlzeit mit Abhak-Knopf.
struct MealRow: View {
    @Environment(AppModel.self) private var model
    let day: DayKey
    let meal: PlannedMeal

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.setEaten(!meal.isEaten, day: day, mealId: meal.id)
            } label: {
                Image(systemName: meal.isEaten ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(meal.isEaten ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(meal.isEaten ? "Als nicht gegessen markieren" : "Als gegessen markieren")

            VStack(alignment: .leading, spacing: 2) {
                Label(meal.mealType.displayName, systemImage: meal.mealType.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.recipe(for: meal)?.name ?? "Unbekanntes Rezept")
                    .font(.body.weight(.medium))
                    .strikethrough(meal.isEaten)
                if meal.servings != 1 {
                    Text(Format.servings(meal.servings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            KcalBadge(kcal: model.kcal(for: meal))
        }
        .padding(.vertical, 2)
    }
}

extension DayKey {
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.setLocalizedDateFormatFromTemplate("EEEE d. MMMM")
        return formatter
    }()

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.setLocalizedDateFormatFromTemplate("EEE d.M.")
        return formatter
    }()

    func title(today: DayKey) -> String {
        if self == today { return "Heute" }
        if self == today.adding(days: 1) { return "Morgen" }
        return Self.weekdayFormatter.string(from: date())
    }

    var shortTitle: String { Self.shortFormatter.string(from: date()) }
}

extension Ingredient {
    func formatted(_ amount: Double) -> String { Format.amount(amount, unit: unit) }
}
