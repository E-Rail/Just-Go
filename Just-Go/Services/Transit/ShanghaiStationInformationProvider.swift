import Foundation

/// Routes a station-information request to its source's provider. Which source a station uses comes
/// from the bundled directory, so adding a city is a provider plus a directory entry.
actor OfficialStationInformationRouter: OfficialStationInformationProviding {
    private let beijing: BeijingStationInformationProvider
    private let shanghai: ShanghaiStationInformationProvider
    private let guangzhou: GuangzhouStationInformationProvider
    private let hangzhou: HangzhouStationInformationProvider

    init(
        beijing: BeijingStationInformationProvider,
        shanghai: ShanghaiStationInformationProvider,
        guangzhou: GuangzhouStationInformationProvider,
        hangzhou: HangzhouStationInformationProvider
    ) {
        self.beijing = beijing
        self.shanghai = shanghai
        self.guangzhou = guangzhou
        self.hangzhou = hangzhou
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        switch request.reference {
        case .beijing:
            return try await beijing.information(for: request)
        case .shanghai:
            return try await shanghai.information(for: request)
        case .guangzhou:
            return try await guangzhou.information(for: request)
        case .hangzhou:
            return try await hangzhou.information(for: request)
        }
    }

    func releaseMemory() async {
        await beijing.releaseMemory()
        await shanghai.releaseMemory()
        await guangzhou.releaseMemory()
        await hangzhou.releaseMemory()
    }
}

/// Fetches Shanghai Metro station information from the operator's JSON endpoints on the rider's
/// device. The recipe is in `StationInfoAPI/sources/sources.json` under `shanghaiMetroOnline`; its
/// two quirks are handled here: the `--` placeholder for train times, and exit ids that are a JSON
/// number at some stations and a string at others.
actor ShanghaiStationInformationProvider: OfficialStationInformationProviding {
    static let cityID = "3100"
    static let host = "m.shmetro.com"
    private static let basePath = "/interface/metromap/metromap.aspx"
    private static let maximumResponseBytes = 1_048_576
    private static let requestTimeout: TimeInterval = 5

    private struct PreparedRequest: Hashable, Sendable {
        let stationID: String
        let lineStationIDs: [String]
        let expectedNames: [String]
        var primaryKey: String { lineStationIDs.first ?? "" }
    }

    private let session: URLSession
    private let diskCache: (any OfficialStationInformationCaching)?
    private let answers = OperatorAnswerCache<PreparedRequest, OfficialStationInformationSnapshot>()
    /// The line list and each line's first/last-train table describe the whole line, not one
    /// station, so every station on a line shares one fetch of each.
    private let lineResponses = OperatorAnswerCache<String, Data>()

    init(session: URLSession? = nil, diskCache: (any OfficialStationInformationCaching)? = nil) {
        self.session = session ?? OperatorHTTP.session(timeout: Self.requestTimeout)
        self.diskCache = diskCache
    }

    func releaseMemory() async {
        await answers.releaseMemory()
        await lineResponses.releaseMemory()
    }

    func information(
        for request: OfficialStationInformationRequest
    ) async throws -> OfficialStationInformationSnapshot {
        let prepared = try Self.prepare(request)
        let session = self.session
        let lineResponses = self.lineResponses
        return try await answers.snapshot(
            for: prepared,
            cityID: Self.cityID,
            stationID: prepared.stationID,
            externalStationID: prepared.primaryKey,
            diskCache: diskCache
        ) {
            try await Self.fetch(prepared, lineResponses: lineResponses, using: session)
        }
    }

    private static func prepare(_ request: OfficialStationInformationRequest) throws -> PreparedRequest {
        guard case .shanghai(let lineStationIDs, let names) = request.reference else {
            throw OfficialStationInformationProviderError.invalidRequest("Non-Shanghai references are handled by their own provider")
        }
        let keys = lineStationIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: #"^\d{4}$"#, options: .regularExpression) != nil }
            .uniqued()
        guard !keys.isEmpty else {
            throw OfficialStationInformationProviderError.invalidRequest("Shanghai station reference has no reviewed four-digit key")
        }
        let identity = try OperatorFieldParsing.reviewedIdentity(of: request, names: names)
        return PreparedRequest(stationID: identity.stationID, lineStationIDs: keys, expectedNames: identity.expectedNames)
    }

    /// One station's live first and last trains, in two phases: line colours and the station record
    /// together, then every line's table together. Each request has its own deadline, so an
    /// interchange served by four lines does not time out on a shared budget.
    private static func fetch(
        _ request: PreparedRequest,
        lineResponses: OperatorAnswerCache<String, Data>,
        using session: URLSession
    ) async throws -> OfficialStationInformationSnapshot {
        async let colorsTask = lineColors(lineResponses: lineResponses, using: session)
        async let stationTask = stationInfo(statID: request.primaryKey, using: session)
        let colors = try await colorsTask
        let station = try await stationTask

        guard let name = OperatorFieldParsing.trimmed(station.nameCn) else {
            throw OfficialStationInformationProviderError.contractViolation("station name missing")
        }
        guard OperatorFieldParsing.isReviewedName(name, in: request.expectedNames) else {
            throw OfficialStationInformationProviderError.contractViolation("station name does not match the reviewed catalog")
        }

        // Indexed, so results keep the catalog's line order whatever order the network answers in.
        let keys = request.lineStationIDs
        let rowsByIndex = try await withThrowingTaskGroup(
            of: (Int, Int, [FirstLastRow]).self
        ) { group -> [Int: (Int, [FirstLastRow])] in
            for (index, key) in keys.enumerated() {
                guard let lineNumber = Int(key.prefix(2)) else { continue }
                group.addTask {
                    (index, lineNumber, try await firstLast(line: lineNumber, statID: key, lineResponses: lineResponses, using: session))
                }
            }
            var collected: [Int: (Int, [FirstLastRow])] = [:]
            for try await (index, lineNumber, rows) in group {
                collected[index] = (lineNumber, rows)
            }
            return collected
        }

        var lines: [OfficialStationLineInformation] = []
        for index in keys.indices {
            guard let (lineNumber, rows) = rowsByIndex[index] else { continue }
            let services = mergedServices(rows)
            guard !services.isEmpty else { continue }
            lines.append(OfficialStationLineInformation(
                lineName: "\(lineNumber)号线",
                lineColorHex: colors[lineNumber],
                services: services
            ))
        }

        return OfficialStationInformationSnapshot(
            stationID: request.stationID,
            stationName: name,
            source: .shanghaiMetroOnline,
            freshness: .live,
            lines: lines,
            exits: station.exits,
            facilityGroups: station.facilityGroups
        )
    }

    // MARK: - Endpoints

    private static func lineColors(
        lineResponses: OperatorAnswerCache<String, Data>,
        using session: URLSession
    ) async throws -> [Int: String] {
        let data = try await lineResponses.value(for: "func=lines") { try await get(query: "func=lines", using: session) }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("lines response invalid")
        }
        var colors: [Int: String] = [:]
        for row in rows {
            guard let lineNumber = intValue(row["line_no"]),
                  let color = OperatorFieldParsing.hexColor(row["color"] as? String) else { continue }
            colors[lineNumber] = color
        }
        return colors
    }

    /// One row of the fltime response: a direction with its first and last train.
    private typealias FirstLastRow = (direction: String, first: String?, last: String?)

    private static func firstLast(
        line: Int,
        statID: String,
        lineResponses: OperatorAnswerCache<String, Data>,
        using session: URLSession
    ) async throws -> [FirstLastRow] {
        let query = "func=fltime&line=\(line)"
        let data = try await lineResponses.value(for: query) { try await get(query: query, using: session) }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw OfficialStationInformationProviderError.contractViolation("fltime response invalid")
        }
        let target = Int(statID)
        return rows.compactMap { row in
            guard intValue(row["stat_id"]) == target,
                  let direction = OperatorFieldParsing.trimmed(row["description"] as? String) else { return nil }
            return (direction, OperatorFieldParsing.placeholderAware(row["first_time"] as? String), OperatorFieldParsing.placeholderAware(row["last_time"] as? String))
        }
    }

    private struct ShanghaiStation {
        let nameCn: String?
        let exits: [OfficialStationExitInformation]
        let facilityGroups: [OfficialStationFacilityGroup]
    }

    private static func stationInfo(
        statID: String,
        using session: URLSession
    ) async throws -> ShanghaiStation {
        let data = try await get(query: "func=stationInfo&stat_id=\(statID)", using: session)
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let station = rows.first else {
            throw OfficialStationInformationProviderError.contractViolation("stationInfo response invalid")
        }
        return ShanghaiStation(
            nameCn: station["name_cn"] as? String,
            exits: exits(from: station["entrance_info"] as? String),
            facilityGroups: toilets(from: station["toilet_position"] as? String)
        )
    }

    // MARK: - Mapping

    private static func exits(from raw: String?) -> [OfficialStationExitInformation] {
        guard let raw, let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lines = root["line"] as? [[String: Any]] else { return [] }
        var results: [OfficialStationExitInformation] = []
        for line in lines {
            for entrance in (line["entrance"] as? [[String: Any]]) ?? [] {
                // The exit id is a JSON number at some stations and a string at others.
                guard let name = stringValue(entrance["id"]) else { continue }
                // Shanghai packs every road an exit reaches into one space-separated string ("西藏南路
                // 复兴东路 盐城路"); split so `details` is one place per element, as Beijing's `nearby`
                // is.
                let details = OperatorFieldParsing.trimmed(entrance["description"] as? String)
                    .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }?
                    .uniqued() ?? []
                let accessible: Bool?
                switch entrance["icon2"] as? String {
                case "w_y.png": accessible = true
                case "w_n.png": accessible = false
                default: accessible = nil
                }
                results.append(OfficialStationExitInformation(
                    name: name,
                    details: details,
                    isAccessible: accessible
                ))
            }
        }
        return results.uniqued(by: \OfficialStationExitInformation.id)
    }

    private static func toilets(from raw: String?) -> [OfficialStationFacilityGroup] {
        guard let raw, let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let toilets = root["toilet"] as? [[String: Any]] else { return [] }
        let name = AppLocalization.text(english: "Restroom", simplified: "卫生间", traditional: "洗手間")
        let items = toilets.compactMap { toilet -> OfficialStationFacilityInformation? in
            guard let location = OperatorFieldParsing.trimmed(toilet["description"] as? String) else { return nil }
            return OfficialStationFacilityInformation(name: name, location: location, availability: .available)
        }.uniqued(by: \OfficialStationFacilityInformation.id)
        return items.isEmpty ? [] : [OfficialStationFacilityGroup(name: name, items: items)]
    }

    /// Groups `func=fltime` rows by direction, keeping the earliest first and latest last train
    /// across a direction's short-turn runs, as the recipe requires.
    private static func mergedServices(
        _ rows: [FirstLastRow]
    ) -> [OfficialStationServiceInformation] {
        var order: [String] = []
        var byDirection: [String: OfficialStationServiceInformation] = [:]
        for row in rows {
            guard row.first != nil || row.last != nil else { continue }
            if let existing = byDirection[row.direction] {
                byDirection[row.direction] = OfficialStationServiceInformation(
                    direction: row.direction,
                    firstTrain: OperatorFieldParsing.preferredServiceTime(existing.firstTrain, row.first, earliest: true),
                    lastTrain: OperatorFieldParsing.preferredServiceTime(existing.lastTrain, row.last, earliest: false),
                    liveTime: nil
                )
            } else {
                order.append(row.direction)
                byDirection[row.direction] = OfficialStationServiceInformation(
                    direction: row.direction,
                    firstTrain: row.first,
                    lastTrain: row.last,
                    liveTime: nil
                )
            }
        }
        return order.compactMap { byDirection[$0] }
    }

    // MARK: - HTTP

    private static func get(query: String, using session: URLSession) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = basePath
        components.query = query
        guard let url = components.url else {
            throw OfficialStationInformationProviderError.invalidRequest("invalid Shanghai query")
        }
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("https://service.shmetro.com/", forHTTPHeaderField: "Referer")
        return try await OperatorHTTP.data(
            for: urlRequest,
            host: host,
            maximumBytes: maximumResponseBytes,
            timeout: requestTimeout,
            using: session
        )
    }

    // MARK: - Helpers

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return OperatorFieldParsing.trimmed(string) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
