import Foundation
import PanefoldCore

/// Everything Panefold keeps, as JSON in its own preferences on this Mac. Never synced, never sent.
enum Store {
    private static var defaults: UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["PANEFOLD_DEFAULTS_SUITE"] { return UserDefaults(suiteName: suite) ?? .standard }
        return .standard
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.info("Couldn't read \(key): \(error)")
            return nil
        }
    }

    static func save(_ value: some Encodable, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func remove(_ key: String) { defaults.removeObject(forKey: key) }

    static var bool: (String) -> Bool = { defaults.bool(forKey: $0) }
    static func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    static func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
}

/// Runs a closure once things settle down, for saving and for coalescing bursts of window events.
final class Debouncer {
    private let delay: TimeInterval
    private var work: DispatchWorkItem?

    init(_ delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: block)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() { work?.cancel() }
}
