import Foundation

/// Rolling `unix|stage|detail` trail of reconnect-lease stages, kept in an
/// append-only file instead of `UserDefaults`.
///
/// Every stage used to rewrite a 24 KB string into the preferences plist, so
/// each breadcrumb rewrote the whole plist — part of build 99's
/// diskwrites_resource budget. Appends here cost one short write; the file is
/// trimmed back to `byteBudget` only when it reaches twice that size. Writes
/// are best-effort and never fsync: this is a forensic aid, not authority.
final class AtriaReconnectLeaseTrail: @unchecked Sendable {
    static let shared = AtriaReconnectLeaseTrail()

    let fileURL: URL
    let byteBudget: Int
    private let lock = NSLock()
    private var legacyDefaultsCleared = false

    init(fileURL: URL = AtriaReconnectLeaseTrail.defaultFileURL(),
         byteBudget: Int = AtriaBLEManager.reconnectLeaseTrailByteBudget) {
        self.fileURL = fileURL
        self.byteBudget = max(256, byteBudget)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("atria-diagnostics", isDirectory: true)
            .appendingPathComponent("reconnect-lease-trail.log")
    }

    func record(_ entry: String, defaults: UserDefaults = .standard) {
        lock.lock()
        defer { lock.unlock() }
        if !legacyDefaultsCleared {
            legacyDefaultsCleared = true
            defaults.removeObject(forKey: AtriaBLEManager.ReconnectLeaseDefaults.trail)
        }
        let line = Data((entry + "\n").utf8)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: line)
        try? handle.close()
        if size + UInt64(line.count) >= UInt64(byteBudget * 2) {
            trimLocked()
        }
    }

    /// Newest-last trail text, bounded to `byteBudget`.
    func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(decoding: wholeLineTail(of: data), as: UTF8.self)
    }

    private func trimLocked() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        try? wholeLineTail(of: data).write(to: fileURL, options: .atomic)
    }

    /// Last `byteBudget` bytes, starting on a whole line so the trail never
    /// opens with a torn entry.
    private func wholeLineTail(of data: Data) -> Data {
        guard data.count > byteBudget else { return data }
        let tail = data.suffix(byteBudget)
        guard let newline = tail.firstIndex(of: 0x0A) else { return Data(tail) }
        return Data(tail[tail.index(after: newline)...])
    }
}
