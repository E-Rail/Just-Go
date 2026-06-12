import Foundation

extension UserDefaults {
    func codableValue<Value: Decodable>(forKey key: String, as type: Value.Type, default defaultValue: Value) -> Value {
        guard let data = data(forKey: key) else { return defaultValue }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.persistence.error("Failed to decode value for key \(key, privacy: .public): \(error)")
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
