import Foundation

/// Bounded retention for files that can always be regenerated or are explicit
/// debug captures. It never traverses subdirectories, follows symlinks, or
/// removes a file outside the supplied directory.
enum AtriaGeneratedArtifactRetention {
    struct Policy: Equatable, Sendable {
        let filenamePrefix: String
        let allowedExtensions: Set<String>
        let maximumFiles: Int
        let maximumBytes: UInt64

        init(filenamePrefix: String,
             allowedExtensions: Set<String>,
             maximumFiles: Int,
             maximumBytes: UInt64) {
            precondition(!filenamePrefix.isEmpty)
            precondition(!allowedExtensions.isEmpty)
            precondition(maximumFiles > 0)
            precondition(maximumBytes > 0)
            self.filenamePrefix = filenamePrefix
            self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() })
            self.maximumFiles = maximumFiles
            self.maximumBytes = maximumBytes
        }
    }

    struct Result: Equatable, Sendable {
        let matchedFiles: Int
        let removedFiles: Int
        let removedBytes: UInt64
        let remainingFiles: Int
        let remainingBytes: UInt64
        let limitSatisfied: Bool
    }

    static let rawExports = Policy(filenamePrefix: "atria-export-",
                                   allowedExtensions: ["zip"],
                                   maximumFiles: 3,
                                   maximumBytes: 256 * 1_024 * 1_024)
    static let diagnosticCaptures = Policy(filenamePrefix: "atria-capture-",
                                           allowedExtensions: ["csv"],
                                           maximumFiles: 20,
                                           maximumBytes: 128 * 1_024 * 1_024)
    /// Daily share-card PNGs live in the app's temporary directory and are
    /// fully regenerable. Keep this prefix deliberately narrower than the
    /// workout and weekly share artifacts, which have separate lifecycles.
    static let shareCards = Policy(filenamePrefix: "atria-share-",
                                   allowedExtensions: ["png"],
                                   maximumFiles: 6,
                                   maximumBytes: 32 * 1_024 * 1_024)
    static let workoutShareCards = Policy(filenamePrefix: "atria-workout-share-",
                                          allowedExtensions: ["png"],
                                          maximumFiles: 4,
                                          maximumBytes: 24 * 1_024 * 1_024)
    static let portableWorkoutExports = Policy(filenamePrefix: "Atria-",
                                                allowedExtensions: ["html"],
                                                maximumFiles: 2,
                                                maximumBytes: 16 * 1_024 * 1_024)

    @discardableResult
    static func prune(in directory: URL,
                      policy: Policy,
                      preserving protectedURLs: Set<URL> = [],
                      fileManager: FileManager = .default) -> Result {
        let normalizedDirectory = directory.standardizedFileURL
        let protectedPaths = Set(protectedURLs.map { $0.standardizedFileURL.path })
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let listed = try? fileManager.contentsOfDirectory(at: normalizedDirectory,
                                                                includingPropertiesForKeys: Array(keys),
                                                                options: [.skipsHiddenFiles]) else {
            return .init(matchedFiles: 0,
                         removedFiles: 0,
                         removedBytes: 0,
                         remainingFiles: 0,
                         remainingBytes: 0,
                         limitSatisfied: true)
        }

        struct Candidate {
            let url: URL
            let bytes: UInt64
            let modifiedAt: Date
            let isProtected: Bool
        }
        var candidates: [Candidate] = []
        for url in listed {
            let normalized = url.standardizedFileURL
            guard normalized.deletingLastPathComponent() == normalizedDirectory,
                  normalized.lastPathComponent.hasPrefix(policy.filenamePrefix),
                  policy.allowedExtensions.contains(normalized.pathExtension.lowercased()),
                  let values = try? normalized.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            candidates.append(.init(url: normalized,
                                    bytes: UInt64(max(0, values.fileSize ?? 0)),
                                    modifiedAt: values.contentModificationDate
                                        ?? values.creationDate
                                        ?? .distantPast,
                                    isProtected: protectedPaths.contains(normalized.path)))
        }
        candidates.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        let matchedFiles = candidates.count
        var remainingFiles = matchedFiles
        var remainingBytes = candidates.reduce(UInt64(0)) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.bytes)
            return overflow ? UInt64.max : sum
        }
        var removedFiles = 0
        var removedBytes: UInt64 = 0
        for candidate in candidates where
            remainingFiles > policy.maximumFiles || remainingBytes > policy.maximumBytes {
            guard !candidate.isProtected else { continue }
            do {
                try fileManager.removeItem(at: candidate.url)
                remainingFiles -= 1
                remainingBytes = remainingBytes >= candidate.bytes
                    ? remainingBytes - candidate.bytes
                    : 0
                removedFiles += 1
                let (sum, overflow) = removedBytes.addingReportingOverflow(candidate.bytes)
                removedBytes = overflow ? UInt64.max : sum
            } catch {
                continue
            }
        }
        return .init(matchedFiles: matchedFiles,
                     removedFiles: removedFiles,
                     removedBytes: removedBytes,
                     remainingFiles: remainingFiles,
                     remainingBytes: remainingBytes,
                     limitSatisfied: remainingFiles <= policy.maximumFiles
                        && remainingBytes <= policy.maximumBytes)
    }
}
