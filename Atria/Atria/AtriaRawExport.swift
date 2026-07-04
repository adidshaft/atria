import Foundation
import Darwin

enum AtriaRawExport {
    static let schemaVersion = 1
    static let schemaHeader = "schemaVersion: 1"
    static let schemaDocument = """
    schemaVersion: 1

    # Atria Raw Export Schema

    All timestamps are Unix milliseconds in UTC. CSV files are ASCII, newline-terminated,
    and use numeric columns only.

    ## hr.csv

    `unix_ms,bpm`

    Every accepted heart-rate sample from saved sessions.

    ## rr.csv

    `unix_ms,rr_ms`

    Raw accepted RR intervals from saved sessions, before any correction.

    ## sleeps.json

    Array of user-confirmed sleep records, including source, confidence, and optional
    stage segments.

    ## workouts.json

    Array of user-confirmed workout records plus any saved session strength sets.

    ## rollups.json

    The daily rollup entries Atria uses for charts and context, including optional
    nutrition context when present.
    """

    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let createdAt: Date
        let hrSamples: Int
        let rrSamples: Int
        let sleeps: Int
        let workouts: Int
        let rollups: Int
    }

    struct ExportTelemetry: Equatable {
        private(set) var peakResidentBytes: UInt64

        mutating func sample() {
            peakResidentBytes = max(peakResidentBytes, Self.currentResidentBytes())
        }

        var peakResidentKilobytes: Int {
            Int(peakResidentBytes / 1024)
        }

        static func currentResidentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_,
                              task_flavor_t(MACH_TASK_BASIC_INFO),
                              rebound,
                              &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return UInt64(info.resident_size)
        }
    }

    @discardableResult
    static func writePackage(to url: URL,
                             sessions: [SavedSession],
                             confirmedSleeps: [UserConfirmedSleep],
                             confirmedWorkouts: [UserConfirmedWorkout],
                             rollups: [DailyRollupStoreEntry],
                             now: Date = Date(),
                             progress: ((String, Int) -> Void)? = nil) throws -> ExportTelemetry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var telemetry = ExportTelemetry(peakResidentBytes: ExportTelemetry.currentResidentBytes())
        var writer = try AtriaZipWriter(url: url)
        try writer.addEntry(name: "hr.csv") { handle in
            try writeHRCSV(sessions: sessions, to: handle) { count in
                progress?("hr.csv", count)
                if count.isMultiple(of: 1_000) { telemetry.sample() }
            }
        }
        telemetry.sample()
        try writer.addEntry(name: "rr.csv") { handle in
            try writeRRCSV(sessions: sessions, to: handle) { count in
                progress?("rr.csv", count)
                if count.isMultiple(of: 1_000) { telemetry.sample() }
            }
        }
        telemetry.sample()
        try writer.addEntry(name: "sleeps.json", data: try encoder.encode(confirmedSleeps))
        telemetry.sample()
        try writer.addEntry(name: "workouts.json", data: try encoder.encode(workoutExportRecords(sessions: sessions,
                                                                                                  confirmedWorkouts: confirmedWorkouts)))
        telemetry.sample()
        try writer.addEntry(name: "rollups.json", data: try encoder.encode(rollups))
        telemetry.sample()
        let manifest = Manifest(schemaVersion: schemaVersion,
                                createdAt: now,
                                hrSamples: sessions.reduce(0) { $0 + $1.points.count },
                                rrSamples: sessions.reduce(0) { $0 + ($1.rrPoints?.count ?? 0) },
                                sleeps: confirmedSleeps.count,
                                workouts: confirmedWorkouts.count,
                                rollups: rollups.count)
        try writer.addEntry(name: "manifest.json", data: try encoder.encode(manifest))
        try writer.addEntry(name: "SCHEMA.md", data: Data(schemaDocument.utf8))
        try writer.finalize()
        telemetry.sample()
        return telemetry
    }

    static func hrRows(sessions: [SavedSession]) -> [String] {
        sessions.flatMap { session in
            session.points.map { point in
                "\(unixMilliseconds(session.start.addingTimeInterval(point.t))),\(point.bpm)\n"
            }
        }
    }

    static func rrRows(sessions: [SavedSession]) -> [String] {
        sessions.flatMap { session in
            (session.rrPoints ?? []).map { point in
                "\(unixMilliseconds(session.start.addingTimeInterval(point.t))),\(point.ms)\n"
            }
        }
    }

    private static func writeHRCSV(sessions: [SavedSession],
                                   to handle: FileHandle,
                                   progress: ((Int) -> Void)? = nil) throws {
        try handle.write(contentsOf: Data("unix_ms,bpm\n".utf8))
        var count = 0
        for session in sessions {
            for point in session.points {
                let row = "\(unixMilliseconds(session.start.addingTimeInterval(point.t))),\(point.bpm)\n"
                try handle.write(contentsOf: Data(row.utf8))
                count += 1
                progress?(count)
            }
        }
    }

    private static func writeRRCSV(sessions: [SavedSession],
                                   to handle: FileHandle,
                                   progress: ((Int) -> Void)? = nil) throws {
        try handle.write(contentsOf: Data("unix_ms,rr_ms\n".utf8))
        var count = 0
        for session in sessions {
            for point in session.rrPoints ?? [] {
                let row = "\(unixMilliseconds(session.start.addingTimeInterval(point.t))),\(point.ms)\n"
                try handle.write(contentsOf: Data(row.utf8))
                count += 1
                progress?(count)
            }
        }
    }

    private struct WorkoutExportRecord: Codable, Equatable {
        let confirmed: UserConfirmedWorkout
        let strengthSets: [LoggedSet]
    }

    private static func workoutExportRecords(sessions: [SavedSession],
                                             confirmedWorkouts: [UserConfirmedWorkout]) -> [WorkoutExportRecord] {
        confirmedWorkouts.map { workout in
            let sets = sessions
                .filter { $0.end >= workout.start && $0.start <= workout.end }
                .flatMap { $0.strengthSets ?? [] }
            return WorkoutExportRecord(confirmed: workout, strengthSets: sets)
        }
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
