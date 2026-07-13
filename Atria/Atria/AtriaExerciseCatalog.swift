import Foundation

enum AtriaWorkoutActivityType: String, CaseIterable, Identifiable, Hashable {
    case strength = "Strength"
    case cardio = "Cardio"
    case running = "Running"
    case walking = "Walking"
    case hiking = "Hiking"
    case cycling = "Cycling"
    case hiit = "HIIT"
    case functionalFitness = "Functional"
    case yoga = "Yoga"
    case pilates = "Pilates"
    case dance = "Dance"
    case sport = "Sport"
    case basketball = "Basketball"
    case football = "Football / soccer"
    case cricket = "Cricket"
    case tennis = "Tennis"
    case badminton = "Badminton"
    case volleyball = "Volleyball"
    case golf = "Golf"
    case martialArts = "Martial arts"
    case swimming = "Swimming"
    case rowing = "Rowing"
    case elliptical = "Elliptical"
    case stairClimber = "Stair climber"
    case jumpRope = "Jump rope"
    case boxing = "Boxing"
    case climbing = "Climbing"
    case mobility = "Mobility"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .cardio: return "figure.mixed.cardio"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .cycling: return "bicycle"
        case .hiit: return "figure.highintensity.intervaltraining"
        case .functionalFitness: return "figure.strengthtraining.functional"
        case .yoga: return "figure.yoga"
        case .pilates: return "figure.pilates"
        case .dance: return "figure.dance"
        case .sport: return "sportscourt"
        case .basketball: return "basketball.fill"
        case .football: return "soccerball"
        case .cricket: return "cricket.ball.fill"
        case .tennis: return "tennis.racket"
        case .badminton: return "figure.badminton"
        case .volleyball: return "volleyball.fill"
        case .golf: return "figure.golf"
        case .martialArts: return "figure.martial.arts"
        case .swimming: return "figure.pool.swim"
        case .rowing: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .stairClimber: return "figure.stair.stepper"
        case .jumpRope: return "figure.jumprope"
        case .boxing: return "figure.boxing"
        case .climbing: return "figure.climbing"
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

    var supportsRouteRecording: Bool {
        switch self {
        case .running, .walking, .hiking, .cycling:
            return true
        default:
            return false
        }
    }

    /// Resolves both modern persisted activity types and older workouts that
    /// only carried a free-form label/subtype. One shared resolver keeps the
    /// Activity list, timeline, Live Activity and share card iconography in
    /// agreement instead of letting each surface fall back to `figure.run`.
    static func resolved(activityType: String?, subtype: String?, label: String) -> Self {
        if let activityType,
           let exact = allCases.first(where: {
               $0.rawValue.localizedCaseInsensitiveCompare(activityType) == .orderedSame
           }) {
            return exact
        }
        let value = "\(activityType ?? "") \(subtype ?? "") \(label)".lowercased()
        if value.contains("walk") || value.contains("steps") { return .walking }
        if value.contains("hike") || value.contains("trail") { return .hiking }
        if value.contains("run") || value.contains("jog") { return .running }
        if value.contains("cycle") || value.contains("cycling") || value.contains("bike") || value.contains("spin") { return .cycling }
        if value.contains("swim") || value.contains("pool") { return .swimming }
        if value.contains("row") { return .rowing }
        if value.contains("elliptical") { return .elliptical }
        if value.contains("stair") { return .stairClimber }
        if value.contains("jump rope") || value.contains("skipping") { return .jumpRope }
        if value.contains("box") || value.contains("spar") { return .boxing }
        if value.contains("climb") || value.contains("boulder") { return .climbing }
        if value.contains("yoga") { return .yoga }
        if value.contains("pilates") { return .pilates }
        if value.contains("dance") || value.contains("zumba") { return .dance }
        if value.contains("mobility") || value.contains("stretch") { return .mobility }
        if value.contains("hiit") || value.contains("tabata") || value.contains("interval") { return .hiit }
        if value.contains("functional") || value.contains("crossfit") || value.contains("metcon") { return .functionalFitness }
        if value.contains("strength") || value.contains("weight") || value.contains("lift") { return .strength }
        if value.contains("basketball") { return .basketball }
        if value.contains("football") || value.contains("soccer") { return .football }
        if value.contains("cricket") { return .cricket }
        if value.contains("badminton") { return .badminton }
        if value.contains("tennis") { return .tennis }
        if value.contains("volleyball") { return .volleyball }
        if value.contains("golf") { return .golf }
        if value.contains("martial") || value.contains("jiu jitsu")
            || value.contains("karate") || value.contains("taekwondo") { return .martialArts }
        if value.contains("sport") {
            return .sport
        }
        if value.contains("cardio") { return .cardio }
        return .other
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
        case .hiking:
            return ["Trail", "Hill", "Backpacking", "Treadmill incline"]
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
        case .elliptical:
            return ["Steady", "Intervals", "Recovery"]
        case .stairClimber:
            return ["Steady", "Intervals", "Weighted"]
        case .jumpRope:
            return ["Steady", "Intervals", "Double-unders"]
        case .boxing:
            return ["Bag work", "Sparring", "Shadow boxing", "Class"]
        case .climbing:
            return ["Bouldering", "Indoor", "Outdoor", "Hangboard"]
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

    /// Returns the catalog spelling for a subtype that belongs to this activity.
    /// Persisted free-form/legacy values must not leak across a type change: an
    /// unknown value is intentionally cleared rather than displayed as a valid
    /// style for an unrelated workout.
    func normalizedSubtype(_ subtype: String?) -> String? {
        guard let candidate = subtype?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        return subtypeOptions.first {
            $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    init?(suggestion: String) {
        switch suggestion.lowercased() {
        case "strength": self = .strength
        case "cardio": self = .cardio
        case "mixed": self = .functionalFitness
        case "walk", "walking": self = .walking
        case "hike", "hiking": self = .hiking
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
    private static let customExerciseCacheLock = NSLock()
    private static var customExerciseCache: (data: Data?, exercises: [String])?

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
        let data = userDefaults.data(forKey: AtriaStrengthLog.customExercisesKey)
        if let cached = cachedCustomExercises(for: data) {
            return cached
        }

        let exercises: [String]
        if let data,
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            exercises = normalizedUnique(decoded)
        } else {
            exercises = []
        }
        cacheCustomExercises(data: data, exercises: exercises)
        return exercises
    }

    static func saveCustomExercises(_ exercises: [String], userDefaults: UserDefaults = .standard) {
        let normalized = normalizedUnique(exercises)
        if let data = try? JSONEncoder().encode(normalized) {
            userDefaults.set(data, forKey: AtriaStrengthLog.customExercisesKey)
            cacheCustomExercises(data: data, exercises: normalized)
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
        let sourceGroups = allGroups(userDefaults: userDefaults)
        return filteredGroups(search: search, groups: sourceGroups)
    }

    static func filteredGroups(search: String, groups sourceGroups: [AtriaWorkoutExerciseGroup]) -> [AtriaWorkoutExerciseGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private static func cachedCustomExercises(for data: Data?) -> [String]? {
        customExerciseCacheLock.lock()
        defer { customExerciseCacheLock.unlock() }
        guard let cache = customExerciseCache, cache.data == data else { return nil }
        return cache.exercises
    }

    private static func cacheCustomExercises(data: Data?, exercises: [String]) {
        customExerciseCacheLock.lock()
        customExerciseCache = (data, exercises)
        customExerciseCacheLock.unlock()
    }
}
