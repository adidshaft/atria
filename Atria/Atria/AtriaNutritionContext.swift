import Foundation

struct AtriaNutritionSummary: Codable, Equatable {
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var waterMl: Double?
    var caffeineMg: Double?
    var lastCaffeineHour: Int?
    var alcoholDrinks: Double?

    var hasData: Bool {
        kcal != nil || proteinG != nil || carbsG != nil || fatG != nil
            || waterMl != nil || caffeineMg != nil || lastCaffeineHour != nil
            || alcoholDrinks != nil
    }

    func autoJournalTags(bodyMassKg: Double?) -> Set<BehaviorJournalEntry.Tag> {
        var tags: Set<BehaviorJournalEntry.Tag> = []
        if let alcoholDrinks, alcoholDrinks >= 1 {
            tags.insert(.alcohol)
        }
        if let lastCaffeineHour, lastCaffeineHour >= 14 {
            tags.insert(.caffeine)
        }
        if let proteinG,
           let bodyMassKg,
           bodyMassKg > 0,
           proteinG >= 1.6 * bodyMassKg {
            tags.insert(.protein)
        }
        return tags
    }

    var fuelSummary: String? {
        var parts: [String] = []
        if let kcal {
            parts.append("\(Int(kcal.rounded())) kcal")
        }
        if let proteinG {
            parts.append("\(Int(proteinG.rounded())) g protein")
        }
        if let alcoholDrinks, alcoholDrinks >= 1 {
            let rounded = Int(alcoholDrinks.rounded())
            parts.append("\(rounded) \(rounded == 1 ? "drink" : "drinks")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum AtriaNutritionContext {
    static let healthReadNutritionKey = "atria.health.readNutrition"

    static func summaryFromHealthKit(kcal: Double?,
                                     proteinG: Double?,
                                     carbsG: Double?,
                                     fatG: Double?,
                                     waterMl: Double?,
                                     caffeineMg: Double?,
                                     latestCaffeineDate: Date?,
                                     alcoholDrinks: Double?,
                                     calendar: Calendar = .current) -> AtriaNutritionSummary? {
        let lastCaffeineHour = latestCaffeineDate.map { calendar.component(.hour, from: $0) }
        let summary = AtriaNutritionSummary(kcal: positive(kcal),
                                            proteinG: positive(proteinG),
                                            carbsG: positive(carbsG),
                                            fatG: positive(fatG),
                                            waterMl: positive(waterMl),
                                            caffeineMg: positive(caffeineMg),
                                            lastCaffeineHour: lastCaffeineHour,
                                            alcoholDrinks: positive(alcoholDrinks))
        return summary.hasData ? summary : nil
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
