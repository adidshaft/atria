import Foundation
import MetricKit
import UIKit

/// Debug/TestFlight main-thread stall log plus MetricKit diagnostic capture.
///
/// Build 99 recorded no HangTracer entries; this keeps a regression visible in
/// the soak log instead of in a user's hand. While the app is active a utility
/// timer pings the main queue every 100 ms; a ping unanswered for 250 ms or
/// more is one stall, appended to `main-thread-stalls.log` with its duration
/// once the main thread answers. The timer is stopped whenever the app is not
/// active, so a backgrounded process pays nothing.
///
/// Stacks come from MetricKit: hang, CPU-exception, disk-write and crash
/// diagnostic payloads (with call-stack trees) are written as JSON under
/// `atria-diagnostics/metrickit/`, where a container pull picks them up next to
/// the stall log — the same evidence the device crash store holds, without a
/// sysdiagnose.
final class AtriaMainThreadWatchdog: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AtriaMainThreadWatchdog()

    static let stallThreshold: TimeInterval = 0.25
    static let pingInterval: TimeInterval = 0.1
    static let stallLogByteBudget = 64 * 1_024

    /// Debug builds and TestFlight (sandbox receipt) only.
    static var isEnabledForThisBuild: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    static func diagnosticsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("atria-diagnostics", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "com.adidshaft.atria.main-thread-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Uptime of the ping the main thread has not answered yet (queue-confined).
    private var outstandingPingUptime: TimeInterval?
    private var installed = false

    /// Call once from `didFinishLaunching` on the main thread.
    func install() {
        guard Self.isEnabledForThisBuild, !installed else { return }
        installed = true
        MXMetricManager.shared.add(self)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in self?.start() }
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in self?.stop() }
    }

    private func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.outstandingPingUptime = nil
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pingInterval,
                           repeating: Self.pingInterval,
                           leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.outstandingPingUptime = nil
        }
    }

    private func tick() {
        guard outstandingPingUptime == nil else { return }
        let sent = ProcessInfo.processInfo.systemUptime
        outstandingPingUptime = sent
        DispatchQueue.main.async { [weak self] in
            let answered = ProcessInfo.processInfo.systemUptime
            self?.queue.async { [weak self] in
                guard let self, self.outstandingPingUptime == sent else { return }
                self.outstandingPingUptime = nil
                let stall = Self.stallDuration(sentUptime: sent, answeredUptime: answered)
                if let stall { self.recordStall(seconds: stall) }
            }
        }
    }

    /// Main-thread latency beyond one ping interval, when it crosses the threshold.
    static func stallDuration(sentUptime: TimeInterval, answeredUptime: TimeInterval) -> TimeInterval? {
        let latency = answeredUptime - sentUptime
        return latency >= stallThreshold ? latency : nil
    }

    private func recordStall(seconds: TimeInterval) {
        let line = "\(Int(Date().timeIntervalSince1970))|main_thread_stall|ms=\(Int(seconds * 1_000))\n"
        AtriaDebugLog("ATRIADBG main_thread_stall ms=%d", Int(seconds * 1_000))
        appendBounded(Data(line.utf8),
                      to: Self.diagnosticsDirectory().appendingPathComponent("main-thread-stalls.log"))
    }

    private func appendBounded(_ data: Data, to url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        try? handle.close()
        if size + UInt64(data.count) > UInt64(Self.stallLogByteBudget * 2),
           let contents = try? Data(contentsOf: url) {
            try? Data(contents.suffix(Self.stallLogByteBudget)).write(to: url, options: .atomic)
        }
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = Self.diagnosticsDirectory().appendingPathComponent("metrickit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for payload in payloads {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            let url = directory.appendingPathComponent("diagnostic-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try? payload.jsonRepresentation().write(to: url, options: .atomic)
        }
        Self.pruneMetricKitDirectory(directory, keepNewest: 60)
    }

    static func pruneMetricKitDirectory(_ directory: URL, keepNewest: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in sorted.dropFirst(keepNewest) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
