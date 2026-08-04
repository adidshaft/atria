import Foundation

/// File-backed resident-memory probe. Reinstated 2026-08-04: per-process-limit
/// jetsams at ~3.45GB recurred on-device this morning (06:07 active, 06:42
/// frontmost) even though every previously-identified whole-archive load is
/// windowed/streamed — so the balloon lane must be re-localized by
/// measurement. The console truncates on the jetsam SIGKILL; a fsync'd file in
/// Documents survives it, which is the one channel that worked on Aug 2.
///
/// Output: `Documents/atria-memprobe.log`, lines `<unix-ts> <residentMB> <note>`.
/// A 250ms sampler emits `sample` lines only when resident moves ≥64MB since
/// the last emitted line (quiet at steady state, dense while ballooning), and
/// call sites can drop `note(...)` breadcrumbs so growth is bracketed by the
/// lane that produced it. Cost when idle: one task_info call per 250ms.
///
/// TEMPORARY DIAGNOSTIC — remove (file + call sites) once the balloon lane is
/// identified and fixed. Keep it out of long-lived release history.
enum AtriaMemprobe {
    // .userInitiated: the 06:53 kill showed the utility-QoS sampler being
    // starved through the terminal allocation burst (last line 767MB, jetsam
    // at 3.45GB) — the probe must outrank the allocator to see the death.
    private static let queue = DispatchQueue(label: "atria.memprobe", qos: .userInitiated)
    private static var handle: FileHandle?
    private static var timer: DispatchSourceTimer?
    private static var lastLoggedResident: UInt64 = 0
    private static var lastHeartbeatAt: TimeInterval = 0
    private static var lastTagMilestone: UInt64 = 0
    private static let deltaThresholdBytes: UInt64 = 64 * 1024 * 1024

    static func start() {
        queue.async {
            guard timer == nil else { return }
            let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("atria-memprobe.log")
            // Rotate at 8MB (2026-08-04): the accumulated log crossed the
            // devicectl file-service transfer cap (~40MB, silently truncated),
            // making the newest — most important — window unreadable. One
            // rotated generation is kept for forensics.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = (attributes?[.size] as? NSNumber)?.intValue, size > 8 * 1024 * 1024 {
                let rotated = url.deletingLastPathComponent()
                    .appendingPathComponent("atria-memprobe.1.log")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            write(line: "start pid=\(ProcessInfo.processInfo.processIdentifier) build=inplace-parser-v1")

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler {
                // Trigger on FOOTPRINT movement — the jetsam metric — not
                // resident (which sat flat through a 3.45GB compressor climb).
                let footprint = currentFootprintBytes()
                let now = Date().timeIntervalSince1970
                let delta = footprint > lastLoggedResident
                    ? footprint - lastLoggedResident
                    : lastLoggedResident - footprint
                // Idle heartbeat every 30s, not 1s: the 1Hz fsync cadence
                // kept the devicectl file service permanently contended, so
                // the log could rarely be pulled (2026-08-04). Movement
                // still logs immediately via the delta trigger.
                guard delta >= deltaThresholdBytes || now - lastHeartbeatAt >= 30 else { return }
                lastHeartbeatAt = now
                lastLoggedResident = footprint
                // Tag attribution at every 512MB footprint milestone: the tag
                // distribution names the allocator class behind a climb.
                let milestone = footprint / (512 * 1024 * 1024)
                if milestone != lastTagMilestone {
                    lastTagMilestone = milestone
                    // size_in_use vs region-dirty separates LIVE small blocks
                    // (a real retainer) from freed-but-dirty churn (allocator
                    // reclaim losing to the burst rate).
                    var stats = malloc_statistics_t()
                    malloc_zone_statistics(nil, &stats)
                    write(line: "vmtags \(vmTagSummary()) | live=\(stats.size_in_use / (1024*1024))MB blocks=\(stats.blocks_in_use)")
                }
                write(line: delta >= deltaThresholdBytes ? "sample" : "beat")
            }
            source.resume()
            timer = source
        }
    }

    /// Drop a lane breadcrumb (always written, with the current resident size).
    static func note(_ label: String) {
        queue.async {
            write(line: label, resident: currentResidentBytes())
        }
    }

    private static func write(line: String, resident: UInt64? = nil) {
        // phys_footprint is the metric jetsam enforces; resident_size hid a
        // 3GB compressor balloon (2026-08-04). Log both: "<fp>F/<res>R".
        let footprintMB = currentFootprintBytes() / (1024 * 1024)
        let residentMB = (resident ?? currentResidentBytes()) / (1024 * 1024)
        let text = "\(Date().timeIntervalSince1970) \(footprintMB)F/\(residentMB)R MB \(line)\n"
        guard let handle, let data = text.data(using: .utf8) else { return }
        _ = try? handle.write(contentsOf: data)
        // fsync so the tail survives the jetsam SIGKILL.
        fsync(handle.fileDescriptor)
    }

    /// Attribute footprint by VM region user_tag: sums (dirtied + swapped)
    /// pages per tag across the task's regions. Names the allocator class
    /// (MALLOC_TINY/SMALL/LARGE/HUGE, mapped file, Swift runtime, …) that
    /// owns a balloon when call-stack tools are unavailable (xctrace's
    /// Allocations store is GUI-only). Costs one region walk (~ms).
    static func vmTagSummary(top: Int = 6) -> String {
        var address: vm_address_t = 0
        var totals: [UInt32: UInt64] = [:]
        let page = UInt64(vm_kernel_page_size)
        while true {
            var size: vm_size_t = 0
            var depth: UInt32 = 0
            var info = vm_region_submap_info_64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_64>.stride / MemoryLayout<Int32>.stride)
            let kr = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) { rebound in
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, rebound, &count)
                }
            }
            guard kr == KERN_SUCCESS else { break }
            let dirty = (UInt64(info.pages_dirtied) + UInt64(info.pages_swapped_out)) * page
            if dirty > 0 { totals[info.user_tag, default: 0] += dirty }
            let previous = address
            address = address &+ size
            if address <= previous { break }
        }
        let names: [UInt32: String] = [1: "malloc", 2: "m_small", 3: "m_large", 4: "m_huge",
                                       5: "sbrk", 6: "realloc", 7: "m_tiny", 8: "m_lg_reusable",
                                       9: "m_lg_reused", 10: "m_nano", 11: "mach_msg", 12: "iokit",
                                       13: "stack", 14: "guard", 20: "dylib", 32: "appkit",
                                       33: "foundation", 35: "cg_image", 53: "swift_meta",
                                       70: "os_log", 80: "mapped_file", 84: "compressed", 99: "dyld"]
        return totals.sorted { $0.value > $1.value }.prefix(top)
            .map { "\(names[$0.key] ?? "tag\($0.key)")=\($0.value / (1024*1024))MB" }
            .joined(separator: " ")
    }

    /// The jetsam-enforced metric (includes compressed + IOKit-mapped dirty).
    static func currentFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    private static func currentResidentBytes() -> UInt64 {
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
