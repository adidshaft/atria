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
/// This wrapper listens to `UserDefaults.didChangeNotification` instead and
/// only publishes when the stored value actually changed, so high-frequency
/// sibling-key writes never invalidate views. In-process cross-view sync is
/// preserved (a write from Settings updates readers elsewhere); out-of-process
/// changes are not observed, which is fine for these app-private keys.
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
    private var observer: NSObjectProtocol?

    @Published private(set) var value: Value

    init(key: String, fallback: Value, store: UserDefaults) {
        self.key = key
        self.fallback = fallback
        self.store = store
        self.value = Value.readDefault(from: store, key: key) ?? fallback
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromStore()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func set(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        Value.writeDefault(newValue, to: store, key: key)
    }

    private func refreshFromStore() {
        let fresh = Value.readDefault(from: store, key: key) ?? fallback
        // Equality gate: this is the dedup that dotted-key AppStorage KVO
        // lacks. Publishing only on real change is what breaks the
        // body-invalidation storm.
        if fresh != value {
            value = fresh
        }
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
