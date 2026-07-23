#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"

ROOT = File.expand_path("..", __dir__)
errors = []

read = lambda do |relative_path|
  File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
end

expected_settings = {
  "CITY_PACK_BASE_URL" => "$(CITY_PACK_SECRET_BASE_URL)",
  "CITY_PACK_MAINLAND_MIRROR_URL" => "$(CITY_PACK_SECRET_MAINLAND_MIRROR_URL)",
  "CITY_PACK_MANIFEST_URL" => "$(CITY_PACK_SECRET_MANIFEST_URL)",
  "CITY_PACK_FALLBACK_BASE_URL" => ""
}.freeze

%w[Debug Release].each do |configuration|
  relative_path = "JustGo/Config/#{configuration}.xcconfig"
  source = read.call(relative_path)
  settings = source.each_line.each_with_object({}) do |line, result|
    match = line.match(/\A([A-Z0-9_]+)\s*=\s*(.*?)\s*\z/)
    result[match[1]] = match[2] if match
  end

  errors << "#{relative_path} must optionally include Secrets.xcconfig" unless source.include?('#include? "Secrets.xcconfig"')
  errors << "#{relative_path} must not contain a literal web URL" if source.match?(%r{https?://}i)
  expected_settings.each do |key, value|
    errors << "#{relative_path} has an unsafe #{key} value" unless settings[key] == value
  end
end

info_plist = read.call("JustGo/JustGo-Info.plist")
expected_settings.each_key do |key|
  errors << "JustGo-Info.plist is missing #{key}" unless info_plist.include?("$(#{key})")
end
%w[NSLocationWhenInUseUsageDescription].each do |key|
  errors << "JustGo-Info.plist is missing #{key}" unless info_plist.include?("<key>#{key}</key>")
end
# The camera was only ever reached through the indoor checkpoint scanner. With that feature gone a
# purpose string would promise App Review a capability no user can exercise.
if info_plist.include?("NSCameraUsageDescription")
  errors << "JustGo must not declare camera access it never uses"
end
if info_plist.include?("NSLocationAlwaysAndWhenInUseUsageDescription")
  errors << "JustGo must not declare always-on location access"
end

retired_paths = %w[
  DataPacks/packs
  Scripts/build_indoor_maps.rb
  Scripts/test_indoor_map_builder.rb
  Scripts/import_beijing_enrichment.rb
  Scripts/import_easy_city_packs.rb
  Scripts/import_new_cities.rb
  Scripts/import_qingdao_city_pack.rb
  JustGo/JustGo-Privacy.plist
].freeze
retired_paths.each do |relative_path|
  absolute_path = File.join(ROOT, relative_path)
  next unless File.file?(absolute_path) || (File.directory?(absolute_path) && !Dir.empty?(absolute_path))

  errors << "retired runtime/data path is present: #{relative_path}"
end

swift_files = Dir.glob(File.join(ROOT, "JustGo", "**", "*.swift")).sort
swift_sources = swift_files.to_h { |path| [path, File.read(path, encoding: "UTF-8")] }

expected_web_literals = Set.new([
  ["JustGo/Views/Map/TransitMapView.swift", "https://www.openstreetmap.org/copyright"],
  ["JustGo/Views/Profile/ProfileView.swift", "https://e-rail.github.io/justgo/docs/privacy/"],
  ["JustGo/Views/Profile/ProfileView.swift", "https://e-rail.github.io/justgo/docs/terms/"],
  ["JustGo/Views/Profile/TransitDataView.swift", "https://data.gov.hk/en/terms-and-conditions"],
  ["JustGo/Views/Profile/TransitDataView.swift", "https://data.gov.tw/license"],
  ["JustGo/Views/Profile/TransitDataView.swift", "https://www.openstreetmap.org/copyright"],
  ["JustGo/Services/Data/OfficialCityPackService.swift", "https://www.bjsubway.com/station/xltcx/"],
  ["JustGo/Services/Data/OfficialCityPackService.swift", "https://www.mtr.bj.cn/service/line/"],
  ["JustGo/Services/Data/OfficialCityPackService.swift", "https://www.mtr.com.hk/en/customer/services/system_map.html"],
  ["JustGo/Services/Data/OfficialCityPackService.swift", "https://www.mlm.com.mo/en/"]
]).freeze

actual_web_literals = Set.new
swift_sources.each do |absolute_path, source|
  relative_path = absolute_path.delete_prefix("#{ROOT}/")
  source.scan(/"(https:\/\/[^"\s]+)"/).flatten.each do |url|
    actual_web_literals << [relative_path, url]
  end
end
unexpected_urls = actual_web_literals - expected_web_literals
missing_urls = expected_web_literals - actual_web_literals
errors.concat(unexpected_urls.map { |path, url| "unexpected runtime web URL in #{path}: #{url}" })
errors.concat(missing_urls.map { |path, url| "required attribution/legal URL missing from #{path}: #{url}" })

policy_path = File.join(ROOT, "JustGo/Services/Data/OfficialCityPackService.swift")
policy_source = swift_sources.fetch(policy_path)
%w[github.com github.io githubusercontent.com jsdelivr.net wikimedia.org wikipedia.org].each do |host|
  errors << "city-pack runtime policy is missing forbidden host #{host}" unless policy_source.include?(%Q{"#{host}"})
end
%w[
  SameOriginRedirectDelegate
  willPerformHTTPRedirection
  maximumManifestBytes
  maximumPackBytes
  session.bytes
  allowedExternalLandingPages
  validatesStation
  stationAccessPoints
  loadGenerationMatches
  pruneSupersededVersions
].each do |marker|
  errors << "city-pack runtime policy is missing #{marker}" unless policy_source.include?(marker)
end
errors << "remote packs must reject unproven service status" unless policy_source.include?("station.serviceStatus == nil")
# Indoor navigation was removed, so there is no longer a manifest field to reject — the runtime
# has no way to consume an indoor graph at all. Assert the absence instead of the guard.
errors << "the city-pack runtime must not regain indoor-map handling" if
  policy_source.downcase.include?("indoormaps")

official_catalog_path = File.join(ROOT, "JustGo/Services/Data/OfficialTransitResourceCatalog.swift")
swift_sources.each do |absolute_path, source|
  next if absolute_path == policy_path

  if absolute_path == official_catalog_path
    defensive_guard = 'target.host?.lowercased() != "commons.wikimedia.org"'
    errors << "official-resource catalog must reject runtime Commons links" unless source.include?(defensive_guard)
    source = source.sub(defensive_guard, "")
  end

  %w[jsdelivr.net wikimedia.org wikipedia.org githubusercontent.com].each do |host|
    errors << "runtime source references forbidden media/data host #{host}: #{absolute_path.delete_prefix("#{ROOT}/")}" if source.include?(host)
  end
end

official_viewer_path = File.join(ROOT, "JustGo/Views/Components/Web/OfficialTransitResourceViewer.swift")
unless File.file?(official_viewer_path)
  errors << "official-resource in-app viewer is missing"
else
  official_viewer_source = File.read(official_viewer_path, encoding: "UTF-8")
  %w[
    WKWebsiteDataStore.nonPersistent
    URLSessionConfiguration.ephemeral
    reloadIgnoringLocalAndRemoteCacheData
    OfficialTransitResourceButton
    PDFView
    maximumBinaryBytes
    fullScreenCover
    canShowMIMEType
    stationInformationReaderScript
    WKUserScript
  ].each do |marker|
    errors << "official-resource viewer is missing #{marker}" unless official_viewer_source.include?(marker)
  end
  errors << "official resources must not use a direct SwiftUI Link" if
    official_viewer_source.include?("Link(destination:")
  errors << "station information must not offer a Safari fallback" unless
    official_viewer_source.include?("resource.kind != .stationInformation")
end

required_official_resource_callers = %w[
  JustGo/Views/Profile/TransitDataView.swift
  JustGo/Views/Route/LiveGoView.swift
  JustGo/Views/Route/TransferStationSheet.swift
  JustGo/Views/Station/StationDetailView+DataSections.swift
].freeze
required_official_resource_callers.each do |relative_path|
  source = swift_sources.fetch(File.join(ROOT, relative_path))
  errors << "#{relative_path} must use the shared in-app official-resource button" unless
    source.include?("OfficialTransitResourceButton(")
end

download_callers = swift_sources.each_with_object([]) do |(absolute_path, source), callers|
  relative_path = absolute_path.delete_prefix("#{ROOT}/")
  callers << relative_path if source.include?("downloadCityPack(") && absolute_path != policy_path
end
unless download_callers == ["JustGo/Views/Profile/TransitDataView.swift"]
  errors << "remote city-pack downloads must only be initiated from TransitDataView: #{download_callers.join(", ")}"
end

image_source = read.call("JustGo/Views/Station/FullScreenStationImageView.swift")
errors << "station media renderer must reject non-file URLs" unless image_source.include?("url.isFileURL")
errors << "runtime network image loading is forbidden" if swift_sources.values.any? { |source| source.include?("AsyncImage") }

realtime_source = read.call("JustGo/Services/Transit/HongKongRealtimeArrivalProvider.swift")
errors << "Hong Kong live arrivals must use HTTPS" unless realtime_source.include?('components.scheme = "https"')
errors << "Hong Kong live arrivals must use DATA.GOV.HK" unless realtime_source.include?('components.host = "rt.data.gov.hk"')

station_information_source = read.call(
  "JustGo/Services/Transit/OfficialStationInformationProvider.swift"
)
%w[
  URLSessionConfiguration.ephemeral
  reloadIgnoringLocalAndRemoteCacheData
  httpCookieStorage
  httpShouldSetCookies
  BeijingStationInformationRedirectDelegate
  maximumResponseBytes
  cacheLifetime
  defaultRateLimitBackoff
  rateLimitedUntil
  Retry-After
  releaseMemory
  stationDeviceLocation
  expectedNames
  OfficialStationFacilityAvailability
  OfficialStationInformationCaching
  diskCache
  freshness
  allowsStoredFallback
].each do |marker|
  errors << "Beijing station-information provider is missing #{marker}" unless
    station_information_source.include?(marker)
end
errors << "Beijing station-information provider must use HTTPS" unless
  station_information_source.include?('components.scheme = "https"')
errors << "Beijing station-information provider must use the fixed official host" unless
  station_information_source.include?('host = "www.bjsubway.com"')
errors << "Beijing station-information provider must use the fixed detail path" unless
  station_information_source.include?('endpointPath = "/api/guanwang/v2/getStationDetail"')
%w[UserDefaults FileManager write(to: createFile].each do |persistence_marker|
  if station_information_source.include?(persistence_marker)
    errors << "Beijing station-information provider must stay storage-free; found #{persistence_marker}"
  end
end

# The device-only snapshot cache is the single sanctioned storage tier for fetched official
# station information: Application Support, backup-excluded, size-capped, wiped by both the
# Clear Cache action and the data-rights epoch cleanup, and never bundled or exported.
station_information_cache = read.call(
  "JustGo/Services/Transit/OfficialStationInformationCache.swift"
)
%w[
  StationInformationCache
  applicationSupportDirectory
  schemaVersion
  isExcludedFromBackup
  maximumEntryBytes
  clearAll
  .atomic
  OfficialStationInformationCaching
].each do |marker|
  errors << "station-information cache is missing #{marker}" unless
    station_information_cache.include?(marker)
end
# The cache format is a published interchange contract, so the document and the code have to move
# together: a reader implementing the schema against a version the app no longer writes gets silent
# mismatches rather than an error.
station_information_schema = read.call("DataPacks/STATION_INFORMATION_SCHEMA.md")
cache_schema_version = station_information_cache[/static let schemaVersion = (\d+)/, 1]
documented_version = station_information_schema[/^# Station Information Schema \(v(\d+)\)/, 1]
if cache_schema_version.nil?
  errors << "station-information cache must declare a schemaVersion"
elsif cache_schema_version != documented_version
  errors << "STATION_INFORMATION_SCHEMA.md documents v#{documented_version.inspect} " \
            "but the cache writes v#{cache_schema_version}"
end
# Every field the schema promises must exist on the Swift types that produce it.
provider_source = read.call("JustGo/Services/Transit/OfficialStationInformationProvider.swift")
%w[
  lineName lineColorHex services direction firstTrain lastTrain liveTime
  stationID stationName source freshness lines exits facilityGroups
  isAccessible availability
].each do |field|
  errors << "station-information schema documents #{field}, which the provider does not define" unless
    provider_source.include?(field)
  errors << "station-information schema is missing documented field #{field}" unless
    station_information_schema.include?(field)
end
# The schema is publishable precisely because it carries no operator content. Keep it that way.
errors << "STATION_INFORMATION_SCHEMA.md must state the link-only licence boundary" unless
  station_information_schema.include?("LicenseRef-External-Link-Only")

%w[URLSession https http:// AsyncBytes].each do |network_marker|
  if station_information_cache.include?(network_marker)
    errors << "station-information cache must be storage-only; found #{network_marker}"
  end
end
app_entry = read.call("JustGo/App/JustGoApp.swift")
errors << "data-rights epoch cleanup must sweep the station-information cache" unless
  app_entry.include?("StationInformationCacheLocation")

# Online station information is a display surface only: route feasibility, planning, and
# confidence must keep deriving accessibility truth from bundled reviewed data.
%w[
  JustGo/Services/Transit/RoutePlanningService.swift
  JustGo/Services/Transit/RouteFeasibilityService.swift
  JustGo/Services/Transit/RouteConfidenceService.swift
].each do |routing_path|
  if read.call(routing_path).include?("OfficialStationInformation")
    errors << "#{routing_path} must not consume online station information"
  end
end

# Clear Cache must stay wired end to end: the pack service exposes the full-clear API and
# Settings actually calls it (through DIContainer.clearAllCaches).
errors << "city-pack service must expose clearAllCaches" unless
  policy_source.include?("func clearAllCaches")
settings_source = read.call("JustGo/Views/Profile/SettingsView.swift")
errors << "Settings must expose the Clear Cache action" unless
  settings_source.include?("clearAllCaches")

station_detail_model = read.call("JustGo/ViewModels/Map/StationDetailViewModel.swift")
errors << "Hong Kong station information must preserve verified unavailable facilities" unless
  station_detail_model.include?("availability: .unavailable")

quick_tag_model = read.call("JustGo/Models/User/StationQuickTag.swift")
quick_tag_service = read.call("JustGo/Services/Data/TripMemoryService.swift")
errors << "Home/Work Quick Tags must stay single-slot via kind exclusivity" unless
  quick_tag_model.include?("var isExclusive: Bool")
errors << "legacy Quick Tags must be normalized on startup" unless
  quick_tag_service.include?("StationQuickTagPolicy.normalized(storedQuickTags)")
errors << "Quick Tag station repair must skip map-place tags" unless
  quick_tag_service.include?("resolvedTargetType == .station")
%w[maximumCount replacementRequired].each do |retired_cap_marker|
  [quick_tag_model, quick_tag_service].each do |source|
    errors << "custom Quick Tags are unlimited; #{retired_cap_marker} must not return" if
      source.include?(retired_cap_marker)
  end
end

project = read.call("JustGo.xcodeproj/project.pbxproj")
%w[BundledCityPacks PrivacyInfo.xcprivacy THIRD_PARTY_NOTICES.md official_transit_resources.json].each do |resource|
  errors << "Xcode resources are missing #{resource}" unless project.include?(resource)
end
errors << "Xcode project is missing OfficialTransitResourceViewer.swift" unless
  project.include?("OfficialTransitResourceViewer.swift")
errors << "Xcode project is missing OfficialStationInformationProvider.swift" unless
  project.include?("OfficialStationInformationProvider.swift")
errors << "Xcode project is missing OfficialStationInformationCache.swift" unless
  project.include?("OfficialStationInformationCache.swift")
%w[indoor_maps.json JustGo-Privacy.plist].each do |retired_resource|
  errors << "Xcode project still references #{retired_resource}" if project.include?(retired_resource)
end

privacy_manifest = File.join(ROOT, "JustGo/Resources/PrivacyInfo.xcprivacy")
errors << "PrivacyInfo.xcprivacy is missing" unless File.file?(privacy_manifest)
if File.file?(privacy_manifest)
  privacy = File.read(privacy_manifest, encoding: "UTF-8")
  errors << "privacy manifest must declare no developer-collected data" unless privacy.match?(
    %r{<key>NSPrivacyCollectedDataTypes</key>\s*<array\s*/>}
  )
  errors << "privacy manifest must not claim location collection" if privacy.include?("NSPrivacyCollectedDataTypeLocation")
  errors << "privacy manifest must declare UserDefaults reason CA92.1" unless
    privacy.include?("NSPrivacyAccessedAPICategoryUserDefaults") && privacy.include?("CA92.1")
  errors << "privacy manifest must disable tracking" unless privacy.match?(
    %r{<key>NSPrivacyTracking</key>\s*<false\s*/>}
  )
end

unless errors.empty?
  warn "runtime-data-policy validation failed:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end

puts "runtime-data-policy validation ok: configured_origins=0 runtime_web_links=#{actual_web_literals.length} remote_pack_callers=1 official_viewer=ephemeral beijing_native=cached_device_only quick_tags=unlimited_custom"
