import Foundation

/// Fetches Hangzhou Metro station information from the operator's JSON endpoint on the rider's
/// device. The recipe is in `StationInfoAPI/sources/sources.json` under `hangzhouMetroOnline`.
///
/// There is no per-station endpoint: `/api/operation/all` returns every line, station and
/// first/last train in one ~350 KB response. It is fetched once and shared, and each station slices
/// it by code.
actor HangzhouStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "3301"
    fileprivate static let host = "www.hzmetro.com"
    private static let endpointPath = "/api/operation/all"
    private static let origin = "https://www.hzmetro.com"
    private static let referer = "https://www.hzmetro.com/operation/siteInquiry"
    /// The whole-network payload is ~350 KB; the ceiling leaves room for new lines without letting
    /// the app read an unbounded response.
    private static let maximumResponseBytes = 4_194_304
    /// Higher than the per-station providers' 5 s: this one request carries the entire city.
    private static let requestTimeout: TimeInterval = 10

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let stationCodes: [String]
        let expectedNames: [String]

        /// The disk cache is keyed by one external ID: the directory's representative, listed first.
        var externalStationID: String { stationCodes.first ?? "" }
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private let network = OperatorAnswerCache<String, HangzhouNetwork>()

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.session = session ?? OperatorHTTP.session(timeout: Self.requestTimeout)
        self.diskCache = diskCache
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let session = self.session
        do {
            let payload = try await network.value(for: Self.endpointPath) { try await Self.fetch(using: session) }
            let snapshot = try Self.snapshot(for: prepared, from: payload)
            if let diskCache {
                Task { await diskCache.store(snapshot, cityID: Self.cityID, externalStationID: prepared.externalStationID) }
            }
            return snapshot
        } catch {
            return try await storedSnapshot(
                replacing: error,
                from: diskCache,
                cityID: Self.cityID,
                stationID: prepared.stationID,
                externalStationID: prepared.externalStationID
            )
        }
    }

    func releaseMemory() async {
        await network.releaseMemory()
    }

    private static func prepare(_ request: OfficialStationInformationRequest) throws -> PreparedRequest {
        guard case .hangzhou(let stationCodes, let names) = request.reference else {
            throw OfficialStationInformationProviderError.invalidRequest("Non-Hangzhou references are handled by their own provider")
        }
        let codes = stationCodes
            .compactMap(OperatorFieldParsing.trimmed)
            .filter { $0.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil }
            .uniqued()
        guard !codes.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest(
                "Hangzhou station reference carries no reviewed numeric station code"
            )
        }
        let identity = try OperatorFieldParsing.reviewedIdentity(of: request, names: names)
        return PreparedRequest(stationID: identity.stationID, stationCodes: codes, expectedNames: identity.expectedNames)
    }

    private static func fetch(using session: URLSession) async throws -> HangzhouNetwork {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = endpointPath
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("official station reference is invalid")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "POST"
        // The endpoint answers HTTP 502 to a request without a same-origin Referer/Origin pair.
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(origin, forHTTPHeaderField: "Origin")
        urlRequest.setValue(referer, forHTTPHeaderField: "Referer")
        urlRequest.httpBody = Data()
        let data = try await OperatorHTTP.data(
            for: urlRequest,
            host: host,
            path: endpointPath,
            maximumBytes: maximumResponseBytes,
            requiresJSON: true,
            timeout: requestTimeout,
            using: session
        )

        let payload: HangzhouPayload
        do {
            payload = try JSONDecoder().decode(HangzhouPayload.self, from: data)
        } catch {
            throw OfficialStationInformationProviderError.contractViolation("response is not valid network JSON")
        }
        guard payload.ok == true, let network = payload.data else {
            throw OfficialStationInformationProviderError.serviceUnavailable(OperatorFieldParsing.trimmed(payload.msg))
        }
        guard !network.stationlist.isEmpty, !network.subwaySiteDetail.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation("network payload carries no stations")
        }
        return network
    }

    private static func snapshot(
        for request: PreparedRequest,
        from network: HangzhouNetwork
    ) throws -> OfficialStationInformationSnapshot {
        let codes = Set(request.stationCodes)
        let listed = network.stationlist.filter { codes.contains($0.stationCode) }
        guard !listed.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation(
                "reviewed station code is absent from the operator's station list"
            )
        }

        // Identity is checked against the station list the reviewed catalog was built from.
        // `subwaySiteDetail` disagrees with it on the 站 suffix for four stations, so there it is
        // matched by code only.
        guard listed.contains(where: { OperatorFieldParsing.isReviewedName($0.stationName, in: request.expectedNames) }) else {
            throw OfficialStationInformationProviderError.contractViolation(
                "station name does not match the reviewed catalog"
            )
        }
        // Titled with the record the catalog pinned as representative: 火车东站's records are 火车东站 (76)
        // and 火车东站（东广场） (150), and the payload lists the east plaza first.
        let representative = listed.first { $0.stationCode == request.stationCodes.first }
        let stationName = representative?.stationName
            ?? listed.first { OperatorFieldParsing.isReviewedName($0.stationName, in: request.expectedNames) }?.stationName
            ?? listed[0].stationName

        var lines: [OfficialStationLineInformation] = []
        for lineName in network.subwaySiteDetail.keys.sorted(by: lineOrdering) {
            guard let directions = network.subwaySiteDetail[lineName] else { continue }
            var services: [OfficialStationServiceInformation] = []
            for direction in directions {
                guard let title = OperatorFieldParsing.trimmed(direction.title) else { continue }
                for stop in direction.allStation where codes.contains(stop.stationCode) {
                    let first = serviceTime(stop.startTime)
                    let last = serviceTime(stop.endTime)
                    guard first != nil || last != nil else { continue }
                    services.append(
                        OfficialStationServiceInformation(
                            direction: title,
                            firstTrain: first,
                            lastTrain: last,
                            liveTime: nil
                        )
                    )
                }
            }
            services = services.uniqued(by: \OfficialStationServiceInformation.id)
            guard !services.isEmpty else { continue }
            lines.append(
                OfficialStationLineInformation(
                    lineName: lineName,
                    lineColorHex: nil,
                    services: services
                )
            )
        }

        guard !lines.isEmpty else {
            throw OfficialStationInformationProviderError.contractViolation(
                "operator publishes no service times for this station"
            )
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: stationName,
            source: .hangzhouMetroOnline,
            freshness: .live,
            serviceDayNote: OperatorFieldParsing.trimmed(network.title),
            // The payload carries neither exits nor facilities; the station page falls back to the
            // bundled sections.
            lines: lines,
            exits: [],
            facilityGroups: []
        )
    }

    /// Line keys are names like "1号线" and "6号线（枸桔弄-双浦）": sorted by leading number, so 2 comes
    /// before 10.
    private static func lineOrdering(_ lhs: String, _ rhs: String) -> Bool {
        let left = leadingNumber(lhs)
        let right = leadingNumber(rhs)
        if left != right {
            return (left ?? Int.max) < (right ?? Int.max)
        }
        return lhs < rhs
    }

    private static func leadingNumber(_ value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// A departure time, or nil where the operator wrote a placeholder or anything that is not one.
    private static func serviceTime(_ value: String?) -> String? {
        guard let value = OperatorFieldParsing.placeholderAware(value),
              value.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

private struct HangzhouPayload: Decodable {
    let ok: Bool?
    let msg: String?
    let data: HangzhouNetwork?
}

struct HangzhouNetwork: Decodable, Sendable {
    let stationlist: [HangzhouListedStation]
    let subwaySiteDetail: [String: [HangzhouDirection]]
    /// The payload's own heading, `工作日时刻表`: the **weekday** timetable, shown with the times.
    let title: String?

    private enum CodingKeys: String, CodingKey {
        case stationlist
        case subwaySiteDetail
        case title
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stationlist = try values.decodeIfPresent([HangzhouListedStation].self, forKey: .stationlist) ?? []
        subwaySiteDetail = try values.decodeIfPresent(
            [String: [HangzhouDirection]].self,
            forKey: .subwaySiteDetail
        ) ?? [:]
        title = try values.decodeIfPresent(String.self, forKey: .title)
    }
}

/// Only identity fields are decoded. `description`, the operator's prose about the station, is
/// licensed content this app neither stores nor displays.
struct HangzhouListedStation: Decodable, Sendable {
    let stationCode: String
    let stationName: String
}

struct HangzhouDirection: Decodable, Sendable {
    let title: String?
    let allStation: [HangzhouStop]

    private enum CodingKeys: String, CodingKey {
        case title
        case allStation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        allStation = try values.decodeIfPresent([HangzhouStop].self, forKey: .allStation) ?? []
    }
}

struct HangzhouStop: Decodable, Sendable {
    let stationCode: String
    let startTime: String?
    let endTime: String?
}
