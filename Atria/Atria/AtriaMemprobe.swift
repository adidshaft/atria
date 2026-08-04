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
    private static let deltaThresholdBytes: UInt64 = 64 * 1024 * 1024

    static func start() {
        queue.async {
            guard timer == nil else { return }
            let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("atria-memprobe.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            write(line: "start pid=\(ProcessInfo.processInfo.processIdentifier)")

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler {
                let resident = currentResidentBytes()
                let now = Date().timeIntervalSince1970
                let delta = resident > lastLoggedResident
                    ? resident - lastLoggedResident
                    : lastLoggedResident - resident
                // Unconditional 1s heartbeat: distinguishes "resident was
                // steady" from "sampler was starved" around a kill.
                guard delta >= deltaThresholdBytes || now - lastHeartbeatAt >= 1 else { return }
                lastHeartbeatAt = now
                lastLoggedResident = resident
                write(line: delta >= deltaThresholdBytes ? "sample" : "beat", resident: resident)
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
        let residentMB = (resident ?? currentResidentBytes()) / (1024 * 1024)
        let text = "\(Date().timeIntervalSince1970) \(residentMB)MB \(line)\n"
        guard let handle, let data = text.data(using: .utf8) else { return }
        _ = try? handle.write(contentsOf: data)
        // fsync so the tail survives the jetsam SIGKILL.
        fsync(handle.fileDescriptor)
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
