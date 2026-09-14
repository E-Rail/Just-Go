import CoreLocation
import Foundation
import MapKit

/// Place search backed by Baidu, which answers Chinese place names Apple's mainland POI search
/// misses. Results arrive in GCJ-02 (`coord_type=2` in, `ret_coordtype=gcj02ll` out), verified
/// against the live API: a wrong parameter returns plausible BD-09 a few hundred metres off.
@MainActor
final class BaiduPlaceSearchProvider: PlaceSearchProviding {
    private let client: BaiduMapsClient

    init(client: BaiduMapsClient) {
        self.client = client
    }

    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var parameters: [(name: String, value: String)] = [(name: "query", value: query)]
        if let region {
            parameters.append((name: "location", value: "\(region.center.latitude),\(region.center.longitude)"))
            parameters.append((name: "radius", value: String(Self.searchRadius(for: region))))
        } else {
            // Baidu requires a circle or a named region; nationwide when the map has not said where
            // the rider is looking.
            parameters.append((name: "region", value: "全国"))
        }
        parameters.append((name: "coord_type", value: "2"))
        parameters.append((name: "ret_coordtype", value: "gcj02ll"))
        parameters.append((name: "page_size", value: String(min(max(limit, 1), 20))))

        let response = try await client.get(
            BaiduPlaceSearchResponse.self,
            path: "/place/v2/search",
            parameters: parameters
        )

        return (response.results ?? []).prefix(limit).compactMap { result in
            guard let name = result.name, let location = result.location else { return nil }
            return TransitPlace(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lng),
                address: result.address,
                source: .poiSearch
            )
        }
    }

    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        // `coordtype`, not `coord_type`: each Baidu endpoint spells it differently.
        let response = try await client.get(
            BaiduReverseGeocodeResponse.self,
            path: "/reverse_geocoding/v3/",
            parameters: [
                (name: "location", value: "\(location.latitude),\(location.longitude)"),
                (name: "coordtype", value: "gcj02ll"),
                (name: "ret_coordtype", value: "gcj02ll")
            ]
        )
        let address = response.result?.formattedAddress
        return TransitPlace(
            name: name ?? address ?? AppLocalization.localized("Current Location"),
            coordinate: location,
            address: address,
            source: .reverseGeocode
        )
    }

    /// Baidu caps circle search at 50 km. Halved because a region describes a width and `radius` a
    /// radius.
    private static func searchRadius(for region: MKCoordinateRegion) -> Int {
        let metresPerDegreeLatitude = 111_320.0
        let radius = region.span.latitudeDelta * metresPerDegreeLatitude / 2
        return Int(min(50_000, max(1_000, radius)))
    }
}

/// Apple wherever Apple can answer, Baidu only where it cannot. Baidu allows 100 place searches and
/// 300 reverse geocodes a day for the whole account; Apple's lookups are unmetered. With no key, or
/// a rate-limited one, the app is exactly what it is without Baidu.
@MainActor
final class CompositePlaceSearchProvider: PlaceSearchProviding {
    private let baidu: BaiduPlaceSearchProvider?
    private let appleMaps: MapKitPlaceSearchProvider

    /// `appleMaps` is built in the body: a default argument is evaluated at the nonisolated call
    /// site, and `MapKitPlaceSearchProvider` is `@MainActor`.
    init(baidu: BaiduPlaceSearchProvider?, appleMaps: MapKitPlaceSearchProvider? = nil) {
        self.baidu = baidu
        self.appleMaps = appleMaps ?? MapKitPlaceSearchProvider()
    }

    /// Apple first, Baidu only where Apple has nothing. Station names are answered offline by the
    /// bundled index before this is reached, so the queries that arrive are ones Apple has a fair
    /// chance at, and Apple costs nothing.
    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace] {
        do {
            let results = try await appleMaps.searchPlaces(keyword: keyword, region: region, limit: limit)
            if !results.isEmpty { return results }
        } catch {
            AppLog.data.info("Apple place search unavailable, trying Baidu: \(error)")
        }
        guard let baidu, Self.prefersBaidu(for: region), Self.containsCJK(keyword) else { return [] }
        return try await baidu.searchPlaces(keyword: keyword, region: region, limit: limit)
    }

    /// Apple first, Baidu only if Apple has nothing: reverse geocoding is not where Apple is weak,
    /// and the app calls it on every "start from my location" and dropped pin against an allowance
    /// of 300 a day.
    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        var applePlace: TransitPlace?
        do {
            let place = try await appleMaps.reverseGeocode(location: location, name: name)
            if place.address?.isEmpty == false { return place }
            applePlace = place
        } catch {
            AppLog.data.info("Apple reverse geocode unavailable, trying Baidu: \(error)")
        }
        // Outside Baidu's coverage Apple's answer stands, with or without an address.
        guard let baidu, Self.prefersBaidu(for: nil, coordinate: location) else {
            if let applePlace { return applePlace }
            return try await appleMaps.reverseGeocode(location: location, name: name)
        }
        return try await baidu.reverseGeocode(location: location, name: name)
    }

    /// Whether the query is one Apple answers badly: a Chinese place name. A Latin-script query
    /// does not justify one of the day's hundred searches.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)       // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // Compatibility Ideographs
        }
    }

    /// Baidu's coverage is Greater China, with the same bounds `Scripts/lib/gcj02.rb` uses to
    /// decide whether GCJ-02 applies: one definition of "China" across Ruby and Swift.
    private static func prefersBaidu(for region: MKCoordinateRegion?, coordinate: CLLocationCoordinate2D? = nil) -> Bool {
        guard let center = coordinate ?? region?.center else { return true }
        return center.longitude >= 72.004 && center.longitude <= 137.8347
            && center.latitude >= 0.8293 && center.latitude <= 55.8271
    }
}

// MARK: - Wire responses

private struct BaiduPlaceSearchResponse: BaiduResponseEnvelope {
    let status: Int
    let message: String?
    let results: [Result]?

    struct Result: Decodable, Sendable {
        let name: String?
        let address: String?
        let location: BaiduCoordinate?
    }
}

private struct BaiduReverseGeocodeResponse: BaiduResponseEnvelope {
    let status: Int
    let message: String?
    let result: Result?

    struct Result: Decodable, Sendable {
        let formattedAddress: String?

        enum CodingKeys: String, CodingKey {
            case formattedAddress = "formatted_address"
        }
    }
}
