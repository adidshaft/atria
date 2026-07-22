import Foundation

/// Streams large historical JSONL archives without materializing each file or
/// decoding rows that are older than the requested projection window.
///
/// The timestamp prefilter deliberately understands only the three scalar
/// fields required to reject an old row. Rows that survive it are still passed
/// through the canonical `HistoricalArchive.Record` decoder and its independent
/// raw-payload validation before they can affect a metric.
struct AtriaHistoricalJSONLRecentScanner {
    struct FileDescriptor: Equatable {
        let url: URL
        let size: UInt64
        let modificationTime: TimeInterval
        let resourceIdentifier: String?

        var path: String { url.path }
        var isCompressed: Bool {
            url.pathExtension == AtriaHistoricalSealedJSONLCompression.artifactExtension
        }
    }

    struct FileState: Equatable {
        let path: String
        let processedOffset: UInt64
        let modificationTime: TimeInterval
        let resourceIdentifier: String?
    }

    struct Source: Equatable {
        let descriptor: FileDescriptor
        let startOffset: UInt64
    }

    enum Plan: Equatable {
        case reuse
        case incremental([Source])
        case rebuild([Source])
    }

    struct Statistics: Equatable {
        var fileReadCount = 0
        var byteCount = 0
        var lineCount = 0
        var candidateLineCount = 0
    }

    struct Result {
        let states: [String: FileState]
        let statistics: Statistics
        let complete: Bool
    }

    static func descriptors(for urls: [URL]) -> [FileDescriptor] {
        var seenPaths = Set<String>()
        var seenResourceIdentifiers = Set<String>()
        return urls.compactMap { url in
            let canonicalURL = url.standardizedFileURL
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
            let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let identifier = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier
                .map { String(describing: $0) }
            guard seenPaths.insert(canonicalURL.path).inserted else { return nil }
            if let identifier,
               !seenResourceIdentifiers.insert(identifier).inserted {
                // A legacy migration can leave two path aliases to the same
                // inode. Reading both inflates launch recovery work without
                // adding evidence; resource identity makes this dedup exact.
                return nil
            }
            return FileDescriptor(url: canonicalURL,
                                  size: size,
                                  modificationTime: modificationTime,
                                  resourceIdentifier: identifier)
        }
    }

    /// Reuses an immutable snapshot only while every source file is still the
    /// same file. Pure tail growth is incremental; replacement, truncation, or
    /// removal rebuilds so an atomic compaction cannot leave stale projections.
    static func plan(
        previousStates: [String: FileState]?,
        current: [FileDescriptor]
    ) -> Plan {
        guard let previousStates else {
            return .rebuild(current.map { Source(descriptor: $0, startOffset: 0) })
        }
        let currentPaths = Set(current.map(\.path))
        guard Set(previousStates.keys).isSubset(of: currentPaths) else {
            return .rebuild(current.map { Source(descriptor: $0, startOffset: 0) })
        }

        var additions: [Source] = []
        for descriptor in current {
            guard let previous = previousStates[descriptor.path] else {
                additions.append(Source(descriptor: descriptor, startOffset: 0))
                continue
            }
            if previous.resourceIdentifier != descriptor.resourceIdentifier
                || descriptor.size < previous.processedOffset
                || (descriptor.size == previous.processedOffset
                    && descriptor.modificationTime != previous.modificationTime) {
                return .rebuild(current.map { Source(descriptor: $0, startOffset: 0) })
            }
            if descriptor.size > previous.processedOffset {
                additions.append(Source(descriptor: descriptor,
                                        startOffset: previous.processedOffset))
            }
        }
        return additions.isEmpty ? .reuse : .incremental(additions)
    }

    static func scan(
        sources: [Source],
        cutoff: TimeInterval,
        chunkSize: Int = 64 * 1024,
        consumeCandidate: (Data) -> Void
    ) -> Result {
        precondition(chunkSize > 0)
        var states: [String: FileState] = [:]
        var statistics = Statistics()
        var complete = true

        for source in sources {
            guard source.startOffset <= source.descriptor.size,
                  (!source.descriptor.isCompressed || source.startOffset == 0) else {
                complete = false
                continue
            }
            do {
                statistics.fileReadCount += 1
                var readOffset = source.startOffset
                var processedOffset = source.startOffset
                var carry = Data()

                func process(_ chunk: Data) {
                    readOffset += UInt64(chunk.count)
                    statistics.byteCount += chunk.count
                    let precedingByteCount = carry.count
                    carry.append(chunk)
                    var lineStart = carry.startIndex
                    var scanIndex = carry.index(carry.startIndex,
                                                offsetBy: precedingByteCount)
                    while scanIndex < carry.endIndex {
                        if carry[scanIndex] == 0x0A {
                            let line = Data(carry[lineStart..<scanIndex])
                            lineStart = carry.index(after: scanIndex)
                            if !line.isEmpty {
                                statistics.lineCount += 1
                                if timestamp(in: line).map({ $0 >= cutoff }) ?? false {
                                    statistics.candidateLineCount += 1
                                    consumeCandidate(line)
                                }
                            }
                        }
                        scanIndex = carry.index(after: scanIndex)
                    }
                    if lineStart != carry.startIndex {
                        carry.removeSubrange(carry.startIndex..<lineStart)
                        processedOffset = readOffset - UInt64(carry.count)
                    }
                }

                if source.descriptor.isCompressed {
                    try AtriaHistoricalJSONLInput.forEachChunk(
                        at: source.descriptor.url,
                        chunkSize: chunkSize,
                        consume: process
                    )
                    guard carry.isEmpty else {
                        complete = false
                        continue
                    }
                    // Compressed sealed artifacts are immutable and cannot be
                    // resumed at decoded byte offsets. The physical EOF is the
                    // stable reuse token for this exact resource identity.
                    processedOffset = source.descriptor.size
                } else {
                    guard let handle = try? FileHandle(forReadingFrom: source.descriptor.url) else {
                        complete = false
                        continue
                    }
                    defer { try? handle.close() }
                    try handle.seek(toOffset: source.startOffset)
                    while readOffset < source.descriptor.size {
                        let remaining = source.descriptor.size - readOffset
                        let count = min(chunkSize, Int(remaining))
                        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                            complete = false
                            break
                        }
                        process(chunk)
                    }
                }

                // A writer can be observed between extending the file and
                // completing its trailing newline. Keep the last complete-line
                // boundary so the next incremental pass rereads that row.
                states[source.descriptor.path] = FileState(
                    path: source.descriptor.path,
                    processedOffset: processedOffset,
                    modificationTime: source.descriptor.modificationTime,
                    resourceIdentifier: source.descriptor.resourceIdentifier
                )
            } catch {
                complete = false
            }
        }
        return Result(states: states, statistics: statistics, complete: complete)
    }

    static func timestamp(in jsonLine: Data) -> TimeInterval? {
        let unix = unsignedInteger(after: correctedUnixKey, in: jsonLine)
            ?? unsignedInteger(after: rawUnixKey, in: jsonLine)
        guard let unix, unix > 0 else { return nil }
        let subsecond = unsignedInteger(after: subsecondKey, in: jsonLine) ?? 0
        guard subsecond < 32_768 else { return nil }
        return TimeInterval(unix) + TimeInterval(subsecond) / 32_768
    }

    private static let correctedUnixKey = Data("\"clockCorrectedUnix7\"".utf8)
    private static let rawUnixKey = Data("\"unix7\"".utf8)
    private static let subsecondKey = Data("\"subsec11\"".utf8)

    private static func unsignedInteger(after key: Data, in data: Data) -> UInt64? {
        guard let keyRange = data.range(of: key) else { return nil }
        var index = keyRange.upperBound
        while index < data.endIndex,
              data[index] == 0x20 || data[index] == 0x09 || data[index] == 0x0D {
            index = data.index(after: index)
        }
        guard index < data.endIndex, data[index] == 0x3A else { return nil }
        index = data.index(after: index)
        while index < data.endIndex,
              data[index] == 0x20 || data[index] == 0x09 || data[index] == 0x0D {
            index = data.index(after: index)
        }
        var value: UInt64 = 0
        var sawDigit = false
        while index < data.endIndex {
            let byte = data[index]
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let (advanced, addOverflow) = multiplied.addingReportingOverflow(UInt64(byte - 0x30))
            guard !multiplyOverflow, !addOverflow else { return nil }
            value = advanced
            index = data.index(after: index)
        }
        return sawDigit ? value : nil
    }
}
