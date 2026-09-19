import Foundation

/// Fetches Guangzhou Metro station information from the operator's JSON endpoints on the rider's
/// device. The recipe is in `StationInfoAPI/sources/sources.json` under `guangzhouMetroOnline`. One
/// `serviceTime/list/{stationShowCode}` call returns every line at the station; colours come from
/// the line list (`metroweb/linestation`).
actor GuangzhouStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "4401"
    static let host = "apis.gzmtr.com"
    private static let serviceTimePath = "/app-map/serviceTime/list/"
    private static let lineStationPath = "/app-map/metroweb/linestation"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let stationShowCode: String
        let expectedNames: [String]
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private let answers = OperatorAnswerCache<PreparedRequest, OfficialStationInformationSnapshot>()
    /// Line name → colour, one fetch for the whole network. Best effort: without it the lines still
    /// render, uncoloured, and a failed fetch is not cached, so a later station tries again.
    private let lineColors = OperatorAnswerCache<String, [String: String]>()

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.session = session ?? OperatorHTTP.session(timeout: Self.requestTimeout)
        self.diskCache = diskCache
    }

    func releaseMemory() async {
        await answers.releaseMemory()
        await lineColors.releaseMemory()
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let session = self.session
        let lineColors = self.lineColors
        return try await answers.snapshot(
            for: prepared,
            cityID: Self.cityID,
            stationID: prepared.stationID,
            externalStationID: prepared.stationShowCode,
            diskCache: diskCache
        ) {
            let colors = (try? await lineColors.value(for: Self.lineStationPath) {
                try await Self.fetchLineColors(using: session)
            }) ?? [:]
            return try await Self.fetch(prepared, colors: colors, using: session)
        }
    }

    private static func prepare(_ request: OfficialStationInformationRequest) throws -> PreparedRequest {
        guard case .guangzhou(let stationShowCode, let names) = request.reference,
              let code = OperatorFieldParsing.trimmed(stationShowCode),
              code.range(of: #"^[0-9A-Za-z]{1,12}$"#, options: .regularExpression) != nil else {
            throw OfficialStationInformationProviderError.invalidRequest("Guangzhou station reference is not a reviewed show code")
        }
        let identity = try OperatorFieldParsing.reviewedIdentity(of: request, names: names)
        return PreparedRequest(stationID: identity.stationID, stationShowCode: code, expectedNames: identity.expectedNames)
    }

    private static func fetch(
        _ request: PreparedRequest,
        colors: [String: String],
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        let data = try await post(path: serviceTimePath + request.stationShowCode, using: session)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["businessObject"] as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("serviceTime response invalid")
        }
        // An empty listing has no station name to verify against: treat it as the service being
        // unavailable, so a stored snapshot can stand in.
        guard let name = rows.compactMap({ OperatorFieldParsing.trimmed($0["stationName"] as? String) }).first else {
            throw OfficialStationInformationProviderError.serviceUnavailable("no service times")
        }
        guard OperatorFieldParsing.isReviewedName(name, in: request.expectedNames) else {
            throw OfficialStationInformationProviderError.contractViolation("station name does not match the reviewed catalog")
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: name,
            source: .guangzhouMetroOnline,
            freshness: .live,
            lines: groupedLines(rows, colors: colors),
            exits: [],
            facilityGroups: []
        )
    }

    private static func fetchLineColors(using session: URLSession) async throws -> [String: String] {
        let data = try await post(path: lineStationPath, using: session)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lines = root["businessObject"] as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("linestation response invalid")
        }
        var colors: [String: String] = [:]
        for line in lines {
            guard let name = OperatorFieldParsing.trimmed(line["lineName"] as? String),
                  let color = OperatorFieldParsing.hexColor(line["lineColor"] as? String) else { continue }
            colors[name] = color
        }
        return colors
    }

    // MARK: - Mapping

    /// Group serviceTime rows into one block per line (`lineCn`), each direction (`toStationName`)
    /// collapsed to a single service window: earliest first train, latest last train.
    private static func groupedLines(
        _ rows: [[String: Any]],
        colors: [String: String]
    ) -> [OfficialStationLineInformation] {
        var lineOrder: [String] = []
        var directionOrder: [String: [String]] = [:]
        var services: [String: [String: OfficialStationServiceInformation]] = [:]

        for row in rows {
            guard let lineName = OperatorFieldParsing.trimmed(row["lineCn"] as? String),
                  let direction = OperatorFieldParsing.trimmed(row["toStationName"] as? String) else { continue }
            let first = OperatorFieldParsing.placeholderAware(row["startTime"] as? String)
            let last = OperatorFieldParsing.placeholderAware(row["endTime"] as? String)
            guard first != nil || last != nil else { continue }

            if services[lineName] == nil {
                lineOrder.append(lineName)
                services[lineName] = [:]
                directionOrder[lineName] = []
            }
            if let existing = services[lineName]?[direction] {
                services[lineName]?[direction] = OfficialStationServiceInformation(
                    direction: direction,
                    firstTrain: OperatorFieldParsing.preferredServiceTime(existing.firstTrain, first, earliest: true),
                    lastTrain: OperatorFieldParsing.preferredServiceTime(existing.lastTrain, last, earliest: false),
                    liveTime: nil
                )
            } else {
                directionOrder[lineName]?.append(direction)
                services[lineName]?[direction] = OfficialStationServiceInformation(
                    direction: direction,
                    firstTrain: first,
                    lastTrain: last,
                    liveTime: nil
                )
            }
        }

        return lineOrder.map { lineName in
            OfficialStationLineInformation(
                lineName: lineName,
                lineColorHex: colors[lineName],
                services: (directionOrder[lineName] ?? []).compactMap { services[lineName]?[$0] }
            )
        }
    }

    // MARK: - HTTP

    private static func post(path: String, using session: URLSession) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("invalid Guangzhou path")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data("{}".utf8)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await OperatorHTTP.data(
            for: urlRequest,
            host: host,
            maximumBytes: maximumResponseBytes,
            timeout: requestTimeout,
            using: session
        )
    }
}
