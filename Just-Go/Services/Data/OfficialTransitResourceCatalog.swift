import Foundation

enum ExternalTransitResourceKind: String, Codable, CaseIterable, Sendable {
    case systemMap
    case locationMap
    case streetMap
    case stationLayout
    case serviceStatus
    case journeyPlanner
    case timetable
    case fareInformation
    case stationInformation
    case accessibility
    case stationFacilities
    case customerService
    case operatorInformation

    enum Group: Int, CaseIterable, Identifiable {
        case maps
        case travel
        case accessibility
        case help

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .maps:
                return AppLocalization.text(english: "Maps", simplified: "地图", traditional: "地圖")
            case .travel:
                return AppLocalization.text(english: "Travel", simplified: "出行", traditional: "出行")
            case .accessibility:
                return AppLocalization.text(english: "Accessibility", simplified: "无障碍", traditional: "無障礙")
            case .help:
                return AppLocalization.text(english: "Help", simplified: "帮助", traditional: "協助")
            }
        }
    }

    var group: Group {
        switch self {
        case .systemMap, .locationMap, .streetMap, .stationLayout:
            return .maps
        case .serviceStatus, .journeyPlanner, .timetable, .fareInformation, .stationInformation:
            return .travel
        case .accessibility, .stationFacilities:
            return .accessibility
        case .customerService, .operatorInformation:
            return .help
        }
    }

    var localizedTitle: String {
        switch self {
        case .systemMap:
            return AppLocalization.text(english: "System Map", simplified: "线路图", traditional: "路線圖")
        case .locationMap:
            return AppLocalization.text(english: "Location Map", simplified: "位置图", traditional: "位置圖")
        case .streetMap:
            return AppLocalization.text(english: "Street Map", simplified: "街道图", traditional: "街道圖")
        case .stationLayout:
            return AppLocalization.text(english: "Station Layout", simplified: "车站布局", traditional: "車站佈局")
        case .serviceStatus:
            return AppLocalization.text(english: "Service Status", simplified: "运营状态", traditional: "營運狀態")
        case .journeyPlanner:
            return AppLocalization.text(english: "Journey Planner", simplified: "行程规划", traditional: "行程規劃")
        case .timetable:
            return AppLocalization.text(english: "Timetables", simplified: "时刻表", traditional: "時刻表")
        case .fareInformation:
            return AppLocalization.text(english: "Fares", simplified: "票价", traditional: "票價")
        case .stationInformation:
            return AppLocalization.text(
                english: "Station Information",
                simplified: "车站信息",
                traditional: "車站資訊"
            )
        case .accessibility:
            return AppLocalization.text(english: "Accessibility", simplified: "无障碍服务", traditional: "無障礙服務")
        case .stationFacilities:
            return AppLocalization.text(english: "Station Facilities", simplified: "车站设施", traditional: "車站設施")
        case .customerService:
            return AppLocalization.text(english: "Customer Service", simplified: "乘客服务", traditional: "乘客服務")
        case .operatorInformation:
            return AppLocalization.text(english: "Operator Information", simplified: "运营方信息", traditional: "營運方資訊")
        }
    }

    var isTransferRelevant: Bool {
        switch self {
        case .locationMap, .streetMap, .stationLayout, .accessibility:
            return true
        default:
            return false
        }
    }
}

enum ExternalTransitResourceScope: String, Codable, Sendable {
    case city
    case station
}

enum ExternalTransitResourceFormat: String, Codable, Sendable {
    case webPage
    case pdf
    case image

    var badgeTitle: String {
        switch self {
        case .webPage:
            return AppLocalization.text(english: "PAGE", simplified: "网页", traditional: "網頁")
        case .pdf:
            return "PDF"
        case .image:
            return AppLocalization.text(english: "IMAGE", simplified: "图片", traditional: "圖片")
        }
    }
}

struct ExternalTransitResource: Codable, Equatable, Identifiable, Sendable {
    let kind: ExternalTransitResourceKind
    let title: String
    let targetURL: String
    let sourcePageURL: String
    let provider: String
    let scope: ExternalTransitResourceScope
    let format: ExternalTransitResourceFormat
    let verifiedAt: String
    let stationID: String?

    var id: String { "\(kind.rawValue)|\(targetURL)|\(stationID ?? "city")" }
    var url: URL? { URL(string: targetURL) }
    var sourceURL: URL? { URL(string: sourcePageURL) }

    // Schema-v2 city packs used this name. Keep decoding compatibility while runtime trust now
    // comes exclusively from OfficialTransitResourceCatalog.
    var landingPageURL: String { targetURL }

    private enum CodingKeys: String, CodingKey {
        case kind
        case title
        case targetURL
        case landingPageURL
        case sourcePageURL
        case provider
        case scope
        case format
        case verifiedAt
        case stationID
    }

    /// Explicit because the custom `init(from:)` below suppresses the memberwise one. Used to
    /// wrap a notice fetched at runtime so it can be opened through the same viewer as a
    /// catalogued resource, rather than growing a second web surface beside it.
    init(
        kind: ExternalTransitResourceKind,
        title: String,
        targetURL: String,
        sourcePageURL: String,
        provider: String,
        scope: ExternalTransitResourceScope,
        format: ExternalTransitResourceFormat,
        verifiedAt: String,
        stationID: String?
    ) {
        self.kind = kind
        self.title = title
        self.targetURL = targetURL
        self.sourcePageURL = sourcePageURL
        self.provider = provider
        self.scope = scope
        self.format = format
        self.verifiedAt = verifiedAt
        self.stationID = stationID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ExternalTransitResourceKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        targetURL = try values.decodeIfPresent(String.self, forKey: .targetURL)
            ?? values.decode(String.self, forKey: .landingPageURL)
        sourcePageURL = try values.decodeIfPresent(String.self, forKey: .sourcePageURL) ?? targetURL
        provider = try values.decode(String.self, forKey: .provider)
        scope = try values.decodeIfPresent(ExternalTransitResourceScope.self, forKey: .scope) ?? .station
        format = try values.decodeIfPresent(ExternalTransitResourceFormat.self, forKey: .format) ?? .webPage
        verifiedAt = try values.decodeIfPresent(String.self, forKey: .verifiedAt) ?? ""
        stationID = try values.decodeIfPresent(String.self, forKey: .stationID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(title, forKey: .title)
        try values.encode(targetURL, forKey: .targetURL)
        try values.encode(sourcePageURL, forKey: .sourcePageURL)
        try values.encode(provider, forKey: .provider)
        try values.encode(scope, forKey: .scope)
        try values.encode(format, forKey: .format)
        try values.encode(verifiedAt, forKey: .verifiedAt)
        try values.encodeIfPresent(stationID, forKey: .stationID)
    }
}

enum OfficialTransitResourceReviewStatus: String, Codable, Sendable {
    case verifiedResources
    case noVerifiedOfficialResource
}

struct OfficialTransitResourceCoverage: Codable, Equatable, Sendable {
    let totalLinks: Int
    let maps: Int
    let travel: Int
    let accessibility: Int
    let help: Int
}

enum OfficialTransitStationInformationStatus: String, Codable, Sendable {
    case exactPage
    case officialContextOnly
    case notOpenForPassengerService
    case noCurrentPassengerService

    /// Whether a rider can board or alight here at all.
    ///
    /// The reviewed catalog marks eight stations that riders cannot use, and every one of them is
    /// in the routable network: a trip can be planned to 福寿岭 or 黄土店 today. This is the single
    /// definition the station header, the route planner and anything added later all read, so a
    /// station's usability can never again be true on one screen and unmentioned on the next.
    var servesPassengers: Bool {
        switch self {
        case .exactPage, .officialContextOnly:
            return true
        case .notOpenForPassengerService, .noCurrentPassengerService:
            return false
        }
    }

    /// Short label for a chip or badge: "Not yet open" versus "No passenger service". The two cases
    /// stay distinct: never opened at all, versus open track with no passenger stop today.
    var serviceStatusLabel: (text: String, icon: String)? {
        switch self {
        case .notOpenForPassengerService:
            return (
                AppLocalization.text(
                    english: "Not yet open",
                    simplified: "尚未开通",
                    traditional: "尚未開通"
                ),
                "hammer.fill"
            )
        case .noCurrentPassengerService:
            return (
                AppLocalization.text(
                    english: "No passenger service",
                    simplified: "暂不办理客运",
                    traditional: "暫不辦理客運"
                ),
                "nosign"
            )
        case .exactPage, .officialContextOnly:
            return nil
        }
    }

    /// Full sentence for a route warning, which has to name the station because the rider is
    /// looking at a whole trip rather than one station's page.
    func routeWarning(stationName: String) -> String? {
        switch self {
        case .notOpenForPassengerService:
            return AppLocalization.text(
                english: "\(stationName) has not opened to passengers yet.",
                simplified: "\(stationName)尚未开通客运。",
                traditional: "\(stationName)尚未開通客運。"
            )
        case .noCurrentPassengerService:
            return AppLocalization.text(
                english: "\(stationName) does not handle passengers at present.",
                simplified: "\(stationName)目前不办理客运。",
                traditional: "\(stationName)目前不辦理客運。"
            )
        case .exactPage, .officialContextOnly:
            return nil
        }
    }
}

struct OfficialTransitResourceStation: Codable, Equatable, Identifiable, Sendable {
    let stationID: String
    let stationName: String
    let stationNameEn: String
    let aliases: [String]
    let providerStationID: String?
    let stationInformationStatus: OfficialTransitStationInformationStatus?
    let resources: [ExternalTransitResource]

    var id: String { stationID }
    var localizedName: String {
        AppLocalization.isChinese ? AppLocalization.chinese(stationName) : stationNameEn
    }
}

struct OfficialTransitResourceCity: Codable, Equatable, Identifiable, Sendable {
    let cityID: String
    let name: String
    let nameEn: String
    let nameTraditional: String
    let reviewStatus: OfficialTransitResourceReviewStatus
    let verifiedAt: String
    let reviewNote: String?
    let officialDomains: [String]
    let resources: [ExternalTransitResource]
    let stationResources: [OfficialTransitResourceStation]
    let coverage: OfficialTransitResourceCoverage

    var id: String { cityID }
    var localizedName: String {
        AppLocalization.text(english: nameEn, simplified: name, traditional: nameTraditional)
    }

    var allResources: [ExternalTransitResource] {
        resources + stationResources.flatMap(\.resources)
    }
}

struct OfficialTransitResourceCatalog: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let cities: [OfficialTransitResourceCity]

    static let empty = OfficialTransitResourceCatalog(schemaVersion: 1, generatedAt: "", cities: [])

    enum ValidationError: Error {
        case missingBundledCatalog
        case invalidCatalog
    }

    private init(schemaVersion: Int, generatedAt: String, cities: [OfficialTransitResourceCity]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.cities = cities
    }

    init(validating data: Data) throws {
        self = try JSONDecoder().decode(OfficialTransitResourceCatalog.self, from: data)
        guard isValid else { throw ValidationError.invalidCatalog }
    }

    static func bundled(in bundle: Bundle = .main) throws -> OfficialTransitResourceCatalog {
        guard let url = bundle.url(forResource: "official_transit_resources", withExtension: "json") else {
            throw ValidationError.missingBundledCatalog
        }
        return try OfficialTransitResourceCatalog(validating: Data(contentsOf: url))
    }

    func city(_ cityID: String) -> OfficialTransitResourceCity? {
        cities.first { $0.cityID == cityID }
    }

    func cityResources(_ cityID: String) -> [ExternalTransitResource] {
        city(cityID)?.resources ?? []
    }

    func stationResources(
        cityID: String,
        stationID: String,
        stationName: String?,
        stationNameEn: String?
    ) -> [ExternalTransitResource] {
        stationResourceRecord(
            cityID: cityID,
            stationID: stationID,
            stationName: stationName,
            stationNameEn: stationNameEn
        )?.resources ?? []
    }

    func stationResourceRecord(
        cityID: String,
        stationID: String,
        stationName: String?,
        stationNameEn: String?
    ) -> OfficialTransitResourceStation? {
        guard let city = city(cityID) else { return nil }
        if let exact = city.stationResources.first(where: { $0.stationID == stationID }) {
            return exact
        }
        let names = [stationName, stationNameEn].compactMap { $0 }.map(Self.normalizedName)
        guard !names.isEmpty else { return nil }
        let matches = city.stationResources.filter { station in
            let candidates = [station.stationName, station.stationNameEn] + station.aliases
            return !Set(candidates.map(Self.normalizedName)).isDisjoint(with: names)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var isValid: Bool {
        guard schemaVersion == 1,
              Set(cities.map(\.cityID)).count == cities.count else { return false }

        for city in cities {
            let stationIDs = city.stationResources.map(\.stationID)
            let allResources = city.allResources
            guard Self.isISODate(city.verifiedAt),
                  city.officialDomains == Array(Set(city.officialDomains)).sorted(),
                  Set(stationIDs).count == stationIDs.count,
                  Set(allResources.map(\.id)).count == allResources.count,
                  !city.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !city.nameEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !city.nameTraditional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

            let stationResources = city.stationResources.flatMap(\.resources)
            guard city.resources.allSatisfy({ validates($0, city: city, expectedScope: .city, stationID: nil) }),
                  city.stationResources.allSatisfy({ station in
                      !station.stationID.isEmpty && station.resources.allSatisfy {
                          validates($0, city: city, expectedScope: .station, stationID: station.stationID)
                      }
                  }),
                  validatesCoverage(city.coverage, resources: city.resources + stationResources) else { return false }

            switch city.reviewStatus {
            case .verifiedResources:
                guard !city.resources.isEmpty || !stationResources.isEmpty else { return false }
            case .noVerifiedOfficialResource:
                guard city.resources.isEmpty,
                      stationResources.isEmpty,
                      city.reviewNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
            }
        }

        return true
    }

    private func validates(
        _ resource: ExternalTransitResource,
        city: OfficialTransitResourceCity,
        expectedScope: ExternalTransitResourceScope,
        stationID: String?
    ) -> Bool {
        guard resource.scope == expectedScope,
              resource.stationID == stationID,
              resource.verifiedAt == city.verifiedAt,
              !resource.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resource.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = safeURL(resource.targetURL, allowedDomains: city.officialDomains),
              let source = safeURL(resource.sourcePageURL, allowedDomains: city.officialDomains),
              !containsTemplate(resource.targetURL),
              !containsTemplate(resource.sourcePageURL),
              !containsArbitraryRedirect(target),
              !containsArbitraryRedirect(source),
              target.host?.lowercased() != "commons.wikimedia.org",
              !isDirectFile(source) else { return false }

        switch resource.format {
        case .webPage:
            return !isDirectFile(target)
        case .pdf:
            return target.pathExtension.lowercased() == "pdf" && target != source
        case .image:
            return ["jpg", "jpeg", "png", "webp"].contains(target.pathExtension.lowercased()) && target != source
        }
    }

    private func safeURL(_ value: String, allowedDomains: [String]) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              allowedDomains.contains(host),
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.fragment == nil else { return nil }
        return components.url
    }

    private func isDirectFile(_ url: URL) -> Bool {
        ["pdf", "jpg", "jpeg", "png", "webp", "gif", "svg"].contains(url.pathExtension.lowercased())
    }

    private func containsTemplate(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return value.contains("{") || value.contains("}") ||
            lowercased.contains("%7b") || lowercased.contains("%7d") ||
            lowercased.contains("%s")
    }

    private func containsArbitraryRedirect(_ url: URL) -> Bool {
        let redirectKeys = Set([
            "continue", "destination", "redirect", "redirect_uri", "redirect_url",
            "return", "return_to", "target", "url", "uri"
        ])
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return queryItems.contains { redirectKeys.contains($0.name.lowercased()) }
    }

    private func validatesCoverage(
        _ coverage: OfficialTransitResourceCoverage,
        resources: [ExternalTransitResource]
    ) -> Bool {
        let count: (ExternalTransitResourceKind.Group) -> Int = { group in
            resources.count { $0.kind.group == group }
        }
        return coverage.totalLinks == resources.count &&
            coverage.maps == count(.maps) &&
            coverage.travel == count(.travel) &&
            coverage.accessibility == count(.accessibility) &&
            coverage.help == count(.help)
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static func isISODate(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil
    }
}
