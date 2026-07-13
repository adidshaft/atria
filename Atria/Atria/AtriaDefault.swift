import SwiftUI
import Combine

/// Drop-in replacement for `@AppStorage` for UserDefaults keys that contain
/// dots (e.g. "atria.target.recovery.greenLower").
///
/// Why this exists: `@AppStorage` observes its key via KVO, and UserDefaults
/// KVO treats dotted keys as key paths. On device this made every write to any
/// `atria.*` diagnostics key re-invalidate every view holding a dotted-key
/// `@AppStorage`, without value-equality dedup. With live strap data flowing
/// (frequent diagnostics writes) the home view re-evaluated its body ~800
/// times per second before the first frame, blowing iOS's 10-20 s scene-create
/// watchdog (0x8BADF00D crash loop, 2026-07-03).
///
/// In-process writes take a key-specific path, while an equality-gated broad
/// refresh handles changes made directly through UserDefaults or externally.
@propertyWrapper
@MainActor
struct AtriaDefault<Value: AtriaDefaultValue>: DynamicProperty {
    @StateObject private var box: AtriaDefaultBox<Value>

    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
        _box = StateObject(wrappedValue: AtriaDefaultBox(key: key, fallback: wrappedValue, store: store))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.set(newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.set($0) })
    }
}

@MainActor
final class AtriaDefaultBox<Value: AtriaDefaultValue>: ObservableObject {
    private let key: String
    private let fallback: Value
    private let store: UserDefaults
    private let changeCenter: AtriaDefaultChangeCenter

    @Published private(set) var value: Value

    init(key: String, fallback: Value, store: UserDefaults) {
        self.key = key
        self.fallback = fallback
        self.store = store
        self.value = Value.readDefault(from: store, key: key) ?? fallback
        self.changeCenter = AtriaDefaultChangeCenter.center(for: store)
        changeCenter.register(self)
    }

    func set(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        changeCenter.write(key: key) {
            Value.writeDefault(newValue, to: store, key: key)
        }
    }

    fileprivate func refreshFromStore() {
        let fresh = Value.readDefault(from: store, key: key) ?? fallback
        // Equality gate: this is the dedup that dotted-key AppStorage KVO
        // lacks. Publishing only on real change is what breaks the
        // body-invalidation storm.
        if fresh != value {
            value = fresh
        }
    }
}

@MainActor
private protocol AtriaDefaultRefreshable: AnyObject {
    var defaultKey: String { get }
    func refreshFromStore()
}

extension AtriaDefaultBox: AtriaDefaultRefreshable {
    fileprivate var defaultKey: String { key }
}

/// One coalescing observer per defaults store. The previous implementation
/// installed an observer for every property-wrapper instance; with ~165 live
/// wrappers, each BLE diagnostic write produced ~165 main-thread callbacks.
/// A single observer now batches bursts into one equality-gated refresh pass.
/// Writes made through AtriaDefault bypass that pass and refresh only their key.
@MainActor
final class AtriaDefaultChangeCenter {
    private final class WeakBox {
        weak var value: (any AtriaDefaultRefreshable)?

        init(_ value: any AtriaDefaultRefreshable) {
            self.value = value
        }
    }

    private static var centers: [ObjectIdentifier: AtriaDefaultChangeCenter] = [:]
    static let externalRefreshInterval: Duration = .seconds(5)

    private let store: UserDefaults
    private var boxesByKey: [String: [WeakBox]] = [:]
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var isPerformingKeyedWrite = false
    private(set) var refreshPassCount = 0
    private(set) var keyedRefreshPassCount = 0

    static func center(for store: UserDefaults) -> AtriaDefaultChangeCenter {
        let id = ObjectIdentifier(store)
        if let existing = centers[id] { return existing }
        let center = AtriaDefaultChangeCenter(store: store)
        centers[id] = center
        return center
    }

    private init(store: UserDefaults) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isPerformingKeyedWrite == false else { return }
                self?.scheduleExternalRefresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    fileprivate func register(_ box: any AtriaDefaultRefreshable) {
        var boxes = boxesByKey[box.defaultKey, default: []]
        boxes.removeAll { $0.value == nil }
        boxes.append(WeakBox(box))
        boxesByKey[box.defaultKey] = boxes
    }

    fileprivate func write(key: String, action: () -> Void) {
        isPerformingKeyedWrite = true
        action()
        isPerformingKeyedWrite = false
        refresh(key: key)
    }

    private func refresh(key: String) {
        keyedRefreshPassCount &+= 1
        guard var boxes = boxesByKey[key] else { return }
        boxes.removeAll { box in
            guard let value = box.value else { return true }
            value.refreshFromStore()
            return false
        }
        if boxes.isEmpty {
            boxesByKey.removeValue(forKey: key)
        } else {
            boxesByKey[key] = boxes
        }
    }

    private func scheduleExternalRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.externalRefreshInterval)
            guard !Task.isCancelled, let self else { return }
            refreshTask = nil
            refreshAll()
        }
    }

    private func refreshAll() {
        refreshPassCount &+= 1
        for key in Array(boxesByKey.keys) {
            guard var boxes = boxesByKey[key] else { continue }
            boxes.removeAll { box in
                guard let value = box.value else { return true }
                value.refreshFromStore()
                return false
            }
            if boxes.isEmpty {
                boxesByKey.removeValue(forKey: key)
            } else {
                boxesByKey[key] = boxes
            }
        }
    }

    func flushPendingExternalRefreshForTesting() {
        guard refreshTask != nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshAll()
    }
}

protocol AtriaDefaultValue: Equatable {
    static func readDefault(from store: UserDefaults, key: String) -> Self?
    static func writeDefault(_ value: Self, to store: UserDefaults, key: String)
}

extension Bool: AtriaDefaultValue {
    static func readDefault(from store: UserDefaults, key: String) -> Bool? {
        store.object(forKey: key) as? Bool
    }
    static func writeDefault(_ value: Bool, to store: UserDefaults, key: String) {
        store.set(value, forKey: key)
    }
}

extension Int: AtriaDefaultValue {
    static func readDefault(from store: UserDefaults, key: String) -> Int? {
        store.object(forKey: key) as? Int
    }
    static func writeDefault(_ value: Int, to store: UserDefaults, key: String) {
        store.set(value, forKey: key)
    }
}

extension Double: AtriaDefaultValue {
    static func readDefault(from store: UserDefaults, key: String) -> Double? {
        // Accept Int-stored values too; UserDefaults number bridging is loose.
        if let number = store.object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
    static func writeDefault(_ value: Double, to store: UserDefaults, key: String) {
        store.set(value, forKey: key)
    }
}

extension String: AtriaDefaultValue {
    static func readDefault(from store: UserDefaults, key: String) -> String? {
        store.string(forKey: key)
    }
    static func writeDefault(_ value: String, to store: UserDefaults, key: String) {
        store.set(value, forKey: key)
    }
}
