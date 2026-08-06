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
        /// True when the scan stopped because it hit `byteBudget`, with all
        /// states valid at complete-line boundaries. `complete` is false in
        /// this case, but unlike a read failure the scan is safely
        /// RESUMABLE: re-plan the remaining sources from `states` and call
        /// again. Callers distinguish this from corruption via this flag.
        var exhaustedByteBudget: Bool = false
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
        byteBudget: Int? = nil,
        onProgress: ((Statistics) -> Void)? = nil,
        consumeCandidate: (Data) -> Void
    ) -> Result {
        precondition(chunkSize > 0)
        var states: [String: FileState] = [:]
        var statistics = Statistics()
        var complete = true
        // Per-pass byte ceiling (2026-08-04 balloon fix): on the device's
        // iOS 27 beta, transient per-line allocations accumulate ~1:1 into
        // phys_footprint for the WHOLE continuous scan (no reclaim until the
        // scan machinery unwinds — proven by parse-and-discard releasing
        // fully only after rec_scan_done). Budgeted passes let the caller
        // unwind between resumable slices so peak memory is per-pass, not
        // per-archive. Compressed sources are all-or-nothing, so their
        // budget check happens before the file starts.
        var exhaustedByteBudget = false

        for source in sources {
            if let byteBudget, statistics.byteCount >= byteBudget {
                exhaustedByteBudget = true
                complete = false
                break
            }
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
                            // Foundation's Data/JSON decoder temporaries are
                            // Objective-C backed on device. A lifetime scan can
                            // process hundreds of thousands of rows on one
                            // utility-queue turn; without a local pool those
                            // temporaries survive until the entire file closes
                            // and have physically driven Atria above 2 GB.
                            // Drain at each complete line while keeping the
                            // canonical bytes and candidate semantics intact.
                            autoreleasepool {
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
                        }
                        scanIndex = carry.index(after: scanIndex)
                    }
                    if lineStart != carry.startIndex {
                        carry.removeSubrange(carry.startIndex..<lineStart)
                        processedOffset = readOffset - UInt64(carry.count)
                    }
                    // Progress is emitted only after this chunk has been fully
                    // consumed. Callers may renew a finite inactivity lease
                    // from the monotonic byte count; a queued or stalled scan
                    // therefore cannot manufacture progress.
                    onProgress?(statistics)
                }

                if source.descriptor.isCompressed {
                    try AtriaHistoricalJSONLInput.forEachChunk(
                        at: source.descriptor.url,
                        chunkSize: chunkSize,
                        // Same per-chunk drain as the uncompressed path below.
                        consume: { chunk in autoreleasepool { process(chunk) } }
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
                        if let byteBudget, statistics.byteCount >= byteBudget {
                            // Resumable stop at a complete-line boundary:
                            // processedOffset already trails the last full
                            // line, so the state written below re-reads any
                            // carry remainder on the next pass.
                            exhaustedByteBudget = true
                            complete = false
                            break
                        }
                        let remaining = source.descriptor.size - readOffset
                        let count = min(chunkSize, Int(remaining))
                        // Per-CHUNK pool (2026-08-04 footprint kill, final
                        // layer): FileHandle.read returns an AUTORELEASED
                        // NSData-backed chunk, and this loop's thread pool
                        // only drains when the whole scan ends — a ~1GB
                        // archive held ~1GB of freed chunks (plus the
                        // decoder's bridged per-line temporaries, ~4x that in
                        // full mode) until the per-process limit killed the
                        // app. The existing per-LINE pool inside process()
                        // could not release objects autoreleased OUTSIDE it.
                        let readComplete = autoreleasepool {
                            guard let chunk = try? handle.read(upToCount: count),
                                  !chunk.isEmpty else {
                                return false
                            }
                            process(chunk)
                            return true
                        }
                        guard readComplete else {
                            complete = false
                            break
                        }
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
        return Result(states: states,
                      statistics: statistics,
                      complete: complete,
                      exhaustedByteBudget: exhaustedByteBudget)
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
