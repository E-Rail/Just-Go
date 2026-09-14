import Foundation

extension UserDefaults {
    func codableValue<Value: Decodable>(forKey key: String, as type: Value.Type, default defaultValue: Value) -> Value {
        guard let data = data(forKey: key) else { return defaultValue }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.persistence.error("Failed to decode value for key \(key, privacy: .public): \(error)")
            // Kept aside before anything can overwrite it: every caller saves its in-memory value
            // back under the same key, so returning the default would turn one unreadable record
            // into an empty history on the next save.
            let backupKey = "\(key).unreadable"
            if object(forKey: backupKey) == nil { set(data, forKey: backupKey) }
            return defaultValue
        }
    }

    func setCodable<Value: Encodable>(_ value: Value, forKey key: String) {
        do {
            set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.persistence.error("Failed to encode value for key \(key, privacy: .public): \(error)")
        }
    }
}
