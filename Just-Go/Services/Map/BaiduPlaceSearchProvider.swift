import CoreLocation
import Foundation
import MapKit

/// Place search backed by Baidu.
///
/// This exists because Apple's mainland POI coverage is thin in Chinese: searching a station name
/// would return four unrelated places and no station, which is the bug that started this. Baidu
/// answers the same query with the station itself, and tags it with the lines that serve it.
///
/// Results arrive in GCJ-02 (`coord_type=2` in, `ret_coordtype=gcj02ll` out), which is the frame
/// the rest of the app draws in, so nothing is converted on the way through. Getting either
/// parameter wrong does not fail: it returns BD-09 that looks entirely plausible and sits a few
/// hundred metres off, so both were verified against the live API before this was written.
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
            // Baidu requires either a circle or a named region; nationwide is the honest default
            // when the map has not told us where the rider is looking.
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
        // Note `coordtype`, not `coord_type`: this endpoint spells it differently from place search,
        // and differently again from directions. Three endpoints, three spellings, all verified.
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

    /// Baidu caps circle search at 50 km. The span is halved because the region describes a full
    /// width while `radius` describes a radius. Passing the span searches four times the area.
    private static func searchRadius(for region: MKCoordinateRegion) -> Int {
        let metresPerDegreeLatitude = 111_320.0
        let radius = region.span.latitudeDelta * metresPerDegreeLatitude / 2
        return Int(min(50_000, max(1_000, radius)))
    }
}

/// Baidu where Baidu is better, Apple everywhere else, and Apple again whenever Baidu says nothing.
///
/// The fallback is not defensive padding: a missing or rate-limited key must degrade the app to
/// exactly what it was before Baidu existed, never to a blank screen. `isConfigured` being false is
/// a normal state: the project builds and runs with no key at all.
@MainActor
final class CompositePlaceSearchProvider: PlaceSearchProviding {
    private let baidu: BaiduPlaceSearchProvider?
    private let appleMaps: MapKitPlaceSearchProvider

    /// `appleMaps` is built in the body rather than defaulted in the signature: a default argument
    /// is evaluated at the call site, which is nonisolated, and `MapKitPlaceSearchProvider` is
    /// `@MainActor`.
    init(baidu: BaiduPlaceSearchProvider?, appleMaps: MapKitPlaceSearchProvider? = nil) {
        self.baidu = baidu
        self.appleMaps = appleMaps ?? MapKitPlaceSearchProvider()
    }

    func searchPlaces(keyword: String, region: MKCoordinateRegion?, limit: Int) async throws -> [TransitPlace] {
        if let baidu, Self.prefersBaidu(for: region), Self.containsCJK(keyword) {
            do {
                let results = try await baidu.searchPlaces(keyword: keyword, region: region, limit: limit)
                if !results.isEmpty { return results }
            } catch {
                AppLog.data.info("Baidu place search unavailable, falling back to Apple: \(error)")
            }
        }
        return try await appleMaps.searchPlaces(keyword: keyword, region: region, limit: limit)
    }

    /// Apple first, and Baidu only if Apple has nothing.
    ///
    /// The opposite of `searchPlaces`, on purpose. Baidu was brought in because Apple's mainland
    /// results for a *Chinese place name* are thin, which is a statement about POI search and not
    /// about turning a coordinate into a street address, where Apple is perfectly good. Reverse
    /// geocoding is also the call the app makes most casually, on launch and on every "start from
    /// my location", and it draws on an allowance of 300 a day shared by every rider.
    func reverseGeocode(location: CLLocationCoordinate2D, name: String?) async throws -> TransitPlace {
        do {
            let place = try await appleMaps.reverseGeocode(location: location, name: name)
            if place.address?.isEmpty == false { return place }
        } catch {
            AppLog.data.info("Apple reverse geocode unavailable, trying Baidu: \(error)")
        }
        guard let baidu, Self.prefersBaidu(for: nil, coordinate: location) else {
            return try await appleMaps.reverseGeocode(location: location, name: name)
        }
        return try await baidu.reverseGeocode(location: location, name: name)
    }

    /// Whether the query is one Apple is known to answer badly.
    ///
    /// Baidu earns its allowance on Chinese place names, which is the bug that brought it in:
    /// searching a station's Chinese name on Apple returned four unrelated places and no station.
    /// A Latin-script query has no such problem and does not justify spending one of the day's
    /// hundred searches, so it goes straight to Apple.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)       // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // Compatibility Ideographs
        }
    }

    /// Baidu's coverage is Greater China; outside it Apple is simply better, so the bounds are the
    /// same ones `Scripts/lib/gcj02.rb` uses to decide whether the GCJ-02 obfuscation applies.
    /// Keeping one definition of "China" across the Ruby and Swift sides is deliberate.
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
