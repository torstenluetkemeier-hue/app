import Foundation

public enum Format {
    private static func number(_ value: Double, maxFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "250 g", "1,5 l", "2 Stk."
    public static func amount(_ value: Double, unit: MeasureUnit) -> String {
        switch unit {
        case .gram:
            return value >= 1000 ? "\(number(value / 1000, maxFractionDigits: 2)) kg" : "\(number(value.rounded(), maxFractionDigits: 0)) g"
        case .milliliter:
            return value >= 1000 ? "\(number(value / 1000, maxFractionDigits: 2)) l" : "\(number(value.rounded(), maxFractionDigits: 0)) ml"
        case .piece:
            return "\(number(value, maxFractionDigits: 2)) Stk."
        }
    }

    public static func packages(_ count: Int, size: Double, unit: MeasureUnit) -> String {
        if unit == .piece && size == 1 { return amount(Double(count), unit: .piece) }
        return "\(count) × \(amount(size, unit: unit))"
    }

    public static func liters(_ milliliters: Int) -> String {
        "\(number(Double(milliliters) / 1000, maxFractionDigits: 2)) l"
    }

    public static func kcal(_ value: Double) -> String {
        "\(number(value.rounded(), maxFractionDigits: 0)) kcal"
    }

    public static func servings(_ value: Double) -> String {
        value == 1 ? "1 Portion" : "\(number(value, maxFractionDigits: 2)) Portionen"
    }

    public static func kilograms(_ value: Double) -> String {
        "\(number(value, maxFractionDigits: 1)) kg"
    }
}
