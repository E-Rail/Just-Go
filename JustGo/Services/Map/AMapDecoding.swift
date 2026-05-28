import Foundation
import CoreLocation

func parseCoordinate(_ value: String) -> CLLocationCoordinate2D? {
    let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { return nil }
    return CLLocationCoordinate2D(latitude: parts[1], longitude: parts[0])
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var decodedValues: [Element] = []
            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) {
                    decodedValues.append(value)
                } else {
                    _ = try? container.decode(DiscardedDecodable.self)
                }
            }
            values = decodedValues
            return
        }

        if let value = try? Element(from: decoder) {
            values = [value]
            return
        }

        values = []
    }
}

private struct DiscardedDecodable: Decodable {}

private struct AMapPolylineValue: Decodable {
    let value: String?

    enum CodingKeys: String, CodingKey {
        case polyline
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let stringValue = try? container.decode(String.self) {
            let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            value = text.isEmpty || text == "[]" ? nil : text
            return
        }

        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            value = container.decodeFlexibleString(forKey: .polyline)
            return
        }

        value = nil
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "[]" ? nil : text
        }

        if let values = try? decodeIfPresent([String].self, forKey: key) {
            let text = values
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return nil
    }

    func decodeFlexiblePolylineString(forKey key: Key) -> String? {
        if let value = decodeFlexibleString(forKey: key) {
            return value
        }

        return (try? decodeIfPresent(AMapPolylineValue.self, forKey: key))??.value
    }

    func decodeLossyArray<Element: Decodable>(forKey key: Key) -> [Element] {
        (try? decodeIfPresent(LossyDecodableArray<Element>.self, forKey: key))??.values ?? []
    }

    func decodeFlexiblePOIArray(forKey key: Key) -> [AMapPlacePOI] {
        if let values = try? decodeIfPresent([AMapPlacePOI].self, forKey: key) {
            return values
        }

        if let values = try? decodeIfPresent(AMapPlacePOIList.self, forKey: key) {
            return values.values
        }

        if let value = try? decodeIfPresent(AMapPlacePOI.self, forKey: key) {
            return [value]
        }

        return []
    }
}

func parseSemicolonCoordinates(_ value: String?) -> [CodableCoordinate] {
    guard let value else { return [] }
    return value
        .split(separator: ";")
        .compactMap { parseCoordinate(String($0)) }
        .map { CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
}

func firstTimeText(from values: [String]) -> String? {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
