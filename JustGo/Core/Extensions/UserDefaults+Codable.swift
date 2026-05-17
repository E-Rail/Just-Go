import Foundation

extension UserDefaults {
    func codableValue<Value: Decodable>(forKey key: String, as type: Value.Type, default defaultValue: Value) -> Value {
        guard let data = data(forKey: key),
              let value = try? JSONDecoder().decode(type, from: data) else {
            return defaultValue
        }
        return value
    }

    func setCodable<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}
