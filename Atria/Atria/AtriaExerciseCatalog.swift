import Foundation

enum AtriaWorkoutActivityType: String, CaseIterable, Identifiable {
    case strength = "Strength"
    case cardio = "Cardio"
    case running = "Running"
    case walking = "Walking"
    case cycling = "Cycling"
    case hiit = "HIIT"
    case functionalFitness = "Functional"
    case yoga = "Yoga"
    case pilates = "Pilates"
    case dance = "Dance"
    case sport = "Sport"
    case swimming = "Swimming"
    case rowing = "Rowing"
    case mobility = "Mobility"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .cardio: return "heart.fill"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .hiit: return "timer"
        case .functionalFitness: return "figure.strengthtraining.functional"
        case .yoga: return "figure.yoga"
        case .pilates: return "figure.cooldown"
        case .dance: return "figure.dance"
        case .sport: return "sportscourt"
        case .swimming: return "figure.pool.swim"
        case .rowing: return "figure.rower"
        case .mobility: return "figure.flexibility"
        case .other: return "ellipsis.circle"
        }
    }

    var supportsExerciseSelection: Bool {
        switch self {
        case .strength, .hiit, .functionalFitness:
            return true
        default:
            return false
        }
    }

    var subtypeOptions: [String] {
        switch self {
        case .strength:
            return ["Push", "Pull", "Legs", "Upper body", "Lower body", "Full body", "Powerlifting", "Bodybuilding"]
        case .dance:
            return ["Freestyle", "Zumba", "Hip-hop", "Bollywood", "Salsa", "Ballet", "Contemporary"]
        case .sport:
            return ["Basketball", "Football", "Soccer", "Tennis", "Badminton", "Cricket", "Golf", "Pickleball", "Volleyball", "Boxing", "Martial arts", "Jiu jitsu", "Climbing", "Hiking"]
        case .cardio:
            return ["Machine", "Outdoor", "Class", "Intervals", "Stair climber", "Elliptical", "Incline walk", "Jump rope"]
        case .running:
            return ["Road", "Trail", "Treadmill", "Intervals", "Tempo", "Long run"]
        case .walking:
            return ["Outdoor", "Treadmill", "Incline", "Recovery"]
        case .cycling:
            return ["Outdoor", "Indoor", "Spin", "Intervals", "Recovery"]
        case .hiit:
            return ["Circuit", "Intervals", "Tabata", "Bootcamp", "Metcon", "Jump rope"]
        case .functionalFitness:
            return ["Mixed", "Circuit", "Cross training", "Kettlebell", "Bodyweight", "Carry work"]
        case .swimming:
            return ["Pool", "Open water", "Laps", "Intervals"]
        case .rowing:
            return ["Machine", "Water", "Intervals", "Steady"]
        case .yoga:
            return ["Vinyasa", "Hatha", "Power", "Yin", "Restorative"]
        case .pilates:
            return ["Mat", "Reformer", "Tower", "Class"]
        case .mobility:
            return ["Stretch", "Warm-up", "Cooldown", "Rehab"]
        default:
            return []
        }
    }

    init?(suggestion: String) {
        switch suggestion.lowercased() {
        case "strength": self = .strength
        case "cardio": self = .cardio
        case "mixed": self = .functionalFitness
        case "walk", "walking": self = .walking
        case "mobility": self = .mobility
        case "hiit": self = .hiit
        default: return nil
        }
    }
}

struct AtriaWorkoutExerciseGroup: Identifiable, Equatable {
    let title: String
    let exercises: [String]

    var id: String { title }
}

enum AtriaWorkoutExerciseCatalog {
    static let groups: [AtriaWorkoutExerciseGroup] = [
        AtriaWorkoutExerciseGroup(title: "Chest", exercises: [
            "Barbell bench press", "Dumbbell bench press", "Incline bench press",
            "Incline dumbbell press", "Decline press", "Machine chest press",
            "Cable chest fly", "Pec deck", "Push-up", "Dips",
            "Landmine press", "Svend press", "Dumbbell pullover"
        ]),
        AtriaWorkoutExerciseGroup(title: "Back", exercises: [
            "Pull-up", "Lat pulldown", "Seated cable row", "Barbell row",
            "Dumbbell row", "T-bar row", "Machine row", "Straight-arm pulldown",
            "Deadlift", "Back extension", "Rack pull", "Meadows row",
            "Single-arm cable row", "Chest-supported dumbbell row"
        ]),
        AtriaWorkoutExerciseGroup(title: "Shoulders", exercises: [
            "Overhead press", "Dumbbell shoulder press", "Machine shoulder press",
            "Lateral raise", "Cable lateral raise", "Front raise", "Rear delt fly",
            "Face pull", "Arnold press", "Shrug", "Upright row",
            "Landmine shoulder press", "Y-raise"
        ]),
        AtriaWorkoutExerciseGroup(title: "Biceps", exercises: [
            "Barbell curl", "Dumbbell curl", "Hammer curl", "Incline curl",
            "Preacher curl", "Cable curl", "Machine curl", "Concentration curl",
            "EZ-bar curl", "Spider curl", "Bayesian cable curl"
        ]),
        AtriaWorkoutExerciseGroup(title: "Triceps", exercises: [
            "Cable pushdown", "Overhead triceps extension", "Skull crusher",
            "Close-grip bench press", "Triceps dip", "Rope pushdown",
            "Single-arm cable extension", "Machine triceps extension",
            "JM press", "Cross-body cable extension"
        ]),
        AtriaWorkoutExerciseGroup(title: "Legs", exercises: [
            "Back squat", "Front squat", "Leg press", "Hack squat",
            "Walking lunge", "Bulgarian split squat", "Leg extension",
            "Lying leg curl", "Seated leg curl", "Calf raise",
            "Goblet squat", "Split squat", "Nordic curl", "Adductor machine"
        ]),
        AtriaWorkoutExerciseGroup(title: "Glutes", exercises: [
            "Hip thrust", "Glute bridge", "Cable kickback", "Machine kickback",
            "Romanian deadlift", "Sumo deadlift", "Step-up", "Hip abduction",
            "B-stance RDL", "Frog pump", "Reverse hyperextension"
        ]),
        AtriaWorkoutExerciseGroup(title: "Core", exercises: [
            "Plank", "Side plank", "Crunch", "Cable crunch", "Hanging leg raise",
            "Captain's chair raise", "Russian twist", "Dead bug", "Ab wheel",
            "Mountain climber", "Pallof press", "Reverse crunch", "Bicycle crunch",
            "Hollow hold", "Farmer carry"
        ]),
        AtriaWorkoutExerciseGroup(title: "Machines", exercises: [
            "Smith machine squat", "Smith machine bench press", "Chest-supported row",
            "Assisted pull-up", "Cable row", "Cable woodchop", "Sled push",
            "Battle ropes", "Stair climber", "Elliptical", "Assault bike",
            "SkiErg", "Leg press calf raise"
        ]),
        AtriaWorkoutExerciseGroup(title: "HIIT", exercises: [
            "Burpee", "Jump squat", "Box jump", "Kettlebell swing", "Medicine ball slam",
            "Sled sprint", "Assault bike interval", "Rower sprint", "Jump rope",
            "High knees", "Battle rope slam", "Wall ball", "Thruster",
            "Devil press", "Bear crawl"
        ]),
        AtriaWorkoutExerciseGroup(title: "Functional", exercises: [
            "Clean", "Power clean", "Snatch", "Kettlebell clean", "Kettlebell snatch",
            "Turkish get-up", "Sandbag carry", "Farmers walk", "Tire flip",
            "Rope climb", "Wall walk", "Toes-to-bar"
        ]),
        AtriaWorkoutExerciseGroup(title: "Bodyweight", exercises: [
            "Air squat", "Pull-up", "Chin-up", "Push-up", "Pike push-up",
            "Handstand push-up", "Dip", "Inverted row", "L-sit",
            "Walking lunge", "Step-up", "Burpee"
        ]),
        AtriaWorkoutExerciseGroup(title: "Cardio", exercises: [
            "Outdoor walk", "Treadmill walk", "Incline walk", "Outdoor run",
            "Treadmill run", "Spin bike", "Stair climber", "Elliptical",
            "Rowing machine", "SkiErg", "Jump rope", "Shadow boxing"
        ]),
        AtriaWorkoutExerciseGroup(title: "Mobility", exercises: [
            "Dynamic stretch", "Cooldown stretch", "Hip mobility", "Thoracic rotation",
            "Ankle mobility", "Shoulder dislocate", "Couch stretch",
            "Hamstring stretch", "World's greatest stretch", "Foam rolling"
        ])
    ]

    static func customExercises(userDefaults: UserDefaults = .standard) -> [String] {
        guard let data = userDefaults.data(forKey: AtriaStrengthLog.customExercisesKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalizedUnique(decoded)
    }

    static func saveCustomExercises(_ exercises: [String], userDefaults: UserDefaults = .standard) {
        let normalized = normalizedUnique(exercises)
        if let data = try? JSONEncoder().encode(normalized) {
            userDefaults.set(data, forKey: AtriaStrengthLog.customExercisesKey)
        }
    }

    static func addCustomExercise(_ exercise: String, userDefaults: UserDefaults = .standard) {
        let name = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saveCustomExercises(customExercises(userDefaults: userDefaults) + [name],
                            userDefaults: userDefaults)
    }

    static func allGroups(userDefaults: UserDefaults = .standard) -> [AtriaWorkoutExerciseGroup] {
        let custom = customExercises(userDefaults: userDefaults)
        guard !custom.isEmpty else { return groups }
        return [AtriaWorkoutExerciseGroup(title: "My exercises", exercises: custom)] + groups
    }

    static func filteredGroups(search: String, userDefaults: UserDefaults = .standard) -> [AtriaWorkoutExerciseGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceGroups = allGroups(userDefaults: userDefaults)
        guard !query.isEmpty else { return sourceGroups }
        return sourceGroups.compactMap { group in
            let matches = group.exercises.filter { $0.lowercased().contains(query) }
            return matches.isEmpty ? nil : AtriaWorkoutExerciseGroup(title: group.title, exercises: matches)
        }
    }

    static func suggestedExercises(for signal: String) -> [String] {
        switch signal.lowercased() {
        case "chest":
            return ["Barbell bench press", "Incline dumbbell press", "Cable chest fly"]
        case "triceps":
            return ["Cable pushdown", "Overhead triceps extension", "Rope pushdown"]
        case "abs", "core":
            return ["Cable crunch", "Hanging leg raise", "Plank"]
        case "walk":
            return ["Incline walk", "Treadmill walk", "Outdoor walk"]
        case "stretch":
            return ["Dynamic stretch", "Cooldown stretch", "Hip mobility"]
        default:
            return groups
                .flatMap(\.exercises)
                .filter { $0.localizedCaseInsensitiveContains(signal) }
                .prefix(3)
                .map { $0 }
        }
    }

    private static func normalizedUnique(_ exercises: [String]) -> [String] {
        var seen = Set<String>()
        return exercises.compactMap { exercise in
            let name = exercise.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !name.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return name
        }
    }
}
