#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"
require "uri"
require_relative "lib/official_transit_resource_catalog"

ROOT = File.expand_path("..", __dir__)
CATALOG_PATH = File.join(ROOT, "DataPacks", "official_transit_resources.json")
BINDINGS_PATH = File.join(ROOT, "DataPacks", "sources", "official-resources", "hong_kong_station_bindings.json")
BEIJING_SOURCE_PATH = File.join(
  ROOT,
  "DataPacks",
  "sources",
  "official-resources",
  "beijing_station_information.json"
)
SERVICE_PATH = File.join(ROOT, "JustGo", "Services", "Data", "OfficialCityPackService.swift")
DIRECT_EXTENSIONS = %w[.pdf .jpg .jpeg .png .webp .gif .svg].freeze
REDIRECT_QUERY_KEYS = OfficialTransitResourceCatalogBuilder::REDIRECT_QUERY_KEYS

def fail_validation(message)
  warn "official transit resource validation failed: #{message}"
  exit 1
end

catalog = JSON.parse(File.read(CATALOG_PATH))
expected = OfficialTransitResourceCatalogBuilder::Builder.new(root: ROOT).build
fail_validation("generated catalog is stale") unless catalog == expected
fail_validation("schema version must be 1") unless catalog.fetch("schemaVersion") == 1

cities = catalog.fetch("cities")
expected_ids = OfficialTransitResourceCatalogBuilder::CATALOG_CITY_IDS
fail_validation("catalog must contain exactly 58 reviewed city records") unless cities.map { |city| city.fetch("cityID") } == expected_ids

all_resources = []
cities.each do |city|
  city_id = city.fetch("cityID")
  domains = city.fetch("officialDomains")
  fail_validation("#{city_id} domains are not sorted and unique") unless domains == domains.uniq.sort

  station_resources = city.fetch("stationResources")
  station_ids = station_resources.map { |station| station.fetch("stationID") }
  fail_validation("#{city_id} has duplicate station records") unless station_ids.uniq.length == station_ids.length

  scoped = city.fetch("resources") + station_resources.flat_map { |station| station.fetch("resources") }
  if city.fetch("reviewStatus") == "noVerifiedOfficialResource"
    fail_validation("#{city_id} no-resource review contains links") unless scoped.empty?
    fail_validation("#{city_id} no-resource review has no note") if city.fetch("reviewNote", "").strip.empty?
  else
    fail_validation("#{city_id} verified review contains no links") if scoped.empty?
  end

  scoped.each do |resource|
    kind = resource.fetch("kind")
    format = resource.fetch("format")
    fail_validation("#{city_id} unknown kind #{kind}") unless OfficialTransitResourceCatalogBuilder::RESOURCE_KINDS.include?(kind)
    fail_validation("#{city_id} unknown format #{format}") unless OfficialTransitResourceCatalogBuilder::RESOURCE_FORMATS.include?(format)
    fail_validation("#{city_id} resource verification date mismatch") unless resource.fetch("verifiedAt") == city.fetch("verifiedAt")
    [resource.fetch("targetURL"), resource.fetch("sourcePageURL")].each do |value|
      fail_validation("#{city_id} resource contains a URL template") if value.match?(/[{}]|%7b|%7d|%s/i)
    end

    target = URI(resource.fetch("targetURL"))
    source = URI(resource.fetch("sourcePageURL"))
    [target, source].each do |url|
      fail_validation("#{city_id} URL must use HTTPS") unless url.scheme == "https"
      fail_validation("#{city_id} URL contains credentials") unless url.userinfo.nil?
      fail_validation("#{city_id} URL uses an undeclared host #{url.host}") unless domains.include?(url.host&.downcase)
      fail_validation("#{city_id} runtime Commons link is forbidden") if url.host&.downcase&.end_with?("wikimedia.org")
      query_keys = URI.decode_www_form(url.query.to_s).map { |key, _value| key.downcase }
      fail_validation("#{city_id} arbitrary redirect URL is forbidden") unless (query_keys & REDIRECT_QUERY_KEYS).empty?
    end

    source_extension = File.extname(source.path).downcase
    fail_validation("#{city_id} source page is a direct file") if DIRECT_EXTENSIONS.include?(source_extension)
    target_extension = File.extname(target.path).downcase
    case format
    when "webPage"
      fail_validation("#{city_id} webpage points to a direct file") if DIRECT_EXTENSIONS.include?(target_extension)
    when "pdf"
      fail_validation("#{city_id} PDF has wrong extension") unless target_extension == ".pdf"
      fail_validation("#{city_id} direct PDF lacks a distinct source page") if target == source
    when "image"
      fail_validation("#{city_id} image has wrong extension") unless %w[.jpg .jpeg .png .webp].include?(target_extension)
      fail_validation("#{city_id} direct image lacks a distinct source page") if target == source
    end
    all_resources << resource
  rescue URI::InvalidURIError => error
    fail_validation("#{city_id} invalid URL: #{error.message}")
  end

  coverage = city.fetch("coverage")
  grouped = scoped.group_by { |resource| resource.fetch("kind") }
  maps = %w[systemMap locationMap streetMap stationLayout].sum { |kind| grouped.fetch(kind, []).length }
  travel = %w[
    serviceStatus journeyPlanner timetable fareInformation stationInformation
  ].sum { |kind| grouped.fetch(kind, []).length }
  access = %w[accessibility stationFacilities].sum { |kind| grouped.fetch(kind, []).length }
  help = %w[customerService operatorInformation].sum { |kind| grouped.fetch(kind, []).length }
  fail_validation("#{city_id} coverage is not derived from links") unless coverage == {
    "totalLinks" => scoped.length,
    "maps" => maps,
    "travel" => travel,
    "accessibility" => access,
    "help" => help
  }
end

beijing_source = JSON.parse(File.read(BEIJING_SOURCE_PATH))
expected_beijing_source_keys = %w[
  canonicalCoverageGaps canonicalStationCount detailPageURL legacyStationPages
  mappedStationCount provider schemaVersion sourceDirectoryURL sourceIndexURL
  sourceIndexSHA256 sourceOnlyStationCount sourceStationCount stationPageCount
  stationPageGapCount stations verifiedAt
]
fail_validation("Beijing source contains undeclared fields") unless
  beijing_source.keys.sort == expected_beijing_source_keys.sort
fail_validation("Beijing source-index checksum is invalid") unless
  beijing_source.fetch("sourceIndexSHA256").match?(/\A[0-9a-f]{64}\z/)
beijing_source.fetch("stations").each do |station|
  fail_validation("#{station.fetch('stationName')} binding contains operator content") unless
    station.keys.sort == %w[
      aliases externalStationID sourcePageURL stationID stationName stationNameEn
    ].sort
  fail_validation("#{station.fetch('stationName')} has invalid official station ID") unless
    station.fetch("externalStationID").match?(/\A\d+\z/)
  source_page = URI(station.fetch("sourcePageURL"))
  query = URI.decode_www_form(source_page.query.to_s)
  fail_validation("#{station.fetch('stationName')} has an invalid direct station page") unless
    source_page.scheme == "https" &&
      source_page.host == "www.bjsubway.com" &&
      source_page.path == "/station/siteinfo.html" &&
      query == [["loc", station.fetch("externalStationID")]]
end
beijing_source.fetch("legacyStationPages").each do |station|
  fail_validation("#{station.fetch('stationName')} legacy page contains undeclared fields") unless
    station.keys.sort == %w[
      aliases reason sourcePageURL stationID stationName stationNameEn
    ].sort
end
beijing_source.fetch("canonicalCoverageGaps").each do |station|
  fail_validation("#{station.fetch('stationName')} gap contains undeclared fields") unless
    station.keys.sort == %w[
      informationStatus reason resources stationID stationName stationNameEn
    ].sort
  unless OfficialTransitResourceCatalogBuilder::STATION_INFORMATION_STATUSES.include?(
    station.fetch("informationStatus")
  )
    fail_validation("#{station.fetch('stationName')} gap has invalid station-information status")
  end
  station.fetch("resources").each do |resource|
    fail_validation("#{station.fetch('stationName')} gap resource contains undeclared fields") unless
      resource.keys.sort == %w[
        format kind provider sourcePageURL targetURL title
      ].sort
    fail_validation("#{station.fetch('stationName')} gap resource has invalid kind") unless
      OfficialTransitResourceCatalogBuilder::RESOURCE_KINDS.include?(resource.fetch("kind"))
    fail_validation("#{station.fetch('stationName')} gap resource must be a webpage") unless
      resource.fetch("format") == "webPage"
  end
end
forbidden_beijing_content_keys = %w[
  contentDesc destStationName events exits facilitys firstTime fixedPosition
  guideUrl lastTime lineNames remind trainSchedules
]
serialized_beijing_source = JSON.generate(beijing_source)
forbidden_beijing_content_keys.each do |key|
  fail_validation("Beijing binding snapshot contains forbidden operator content key #{key}") if
    serialized_beijing_source.include?(%("#{key}"))
end

beijing = cities.find { |city| city.fetch("cityID") == "1100" }
beijing_station_resources = beijing.fetch("stationResources")
beijing_station_pages = beijing_station_resources.flat_map { |station| station.fetch("resources") }
  .select { |resource| resource.fetch("kind") == "stationInformation" }
fail_validation("Beijing must review all 444 canonical stations") unless beijing_station_resources.length == 444
fail_validation("Beijing must expose 418 exact station pages") unless beijing_station_pages.length == 418
beijing_provider_references = beijing_station_resources.each_with_object([]) do |station, references|
  references << station["providerStationID"] if station.key?("providerStationID")
end
fail_validation("Beijing must expose 416 reviewed native provider references") unless
  beijing_provider_references.length == 416
fail_validation("Beijing native provider references must be unique nine-digit IDs") unless
  beijing_provider_references.uniq.length == 416 &&
    beijing_provider_references.all? { |station_id| station_id.match?(/\A\d{9}\z/) }
fail_validation("Beijing source station count changed") unless beijing_source.fetch("sourceStationCount") == 423
fail_validation("Beijing native mapping count changed") unless beijing_source.fetch("mappedStationCount") == 416
fail_validation("Beijing Subway station-page coverage changed") unless beijing_source.fetch("stationPageCount") == 417
fail_validation("Beijing station-page gap count changed") unless beijing_source.fetch("stationPageGapCount") == 27
fail_validation("Beijing station-page counts are inconsistent") unless
  beijing_source.fetch("stationPageCount") + beijing_source.fetch("stationPageGapCount") ==
    beijing_source.fetch("canonicalStationCount")
fail_validation("Beijing canonical gap count changed") unless beijing_source.fetch("canonicalCoverageGaps").length == 28
fail_validation("Beijing official-only station count changed") unless beijing_source.fetch("sourceOnlyStationCount") == 7
expected_beijing_ids = (
  beijing_source.fetch("stations") +
  beijing_source.fetch("legacyStationPages") +
  beijing_source.fetch("canonicalCoverageGaps")
).map { |station| station.fetch("stationID") }.uniq.sort
catalog_beijing_ids = beijing_station_resources.map { |station| station.fetch("stationID") }.sort
fail_validation("Beijing canonical station mapping drifted") unless catalog_beijing_ids == expected_beijing_ids
beijing_station_resources.each do |station|
  resources = station.fetch("resources")
  station_information_count = resources.count { |resource| resource.fetch("kind") == "stationInformation" }
  case station.fetch("stationInformationStatus")
  when "exactPage"
    fail_validation("#{station.fetch('stationName')} must have one exact station page") unless
      station_information_count == 1
  when "officialContextOnly", "notOpenForPassengerService"
    fail_validation("#{station.fetch('stationName')} must have official context but no exact page") unless
      station_information_count.zero? && !resources.empty?
  when "noCurrentPassengerService"
    fail_validation("#{station.fetch('stationName')} must not expose invented rider resources") unless
      resources.empty?
  else
    fail_validation("#{station.fetch('stationName')} has an unknown review status")
  end
end
status_counts = beijing_station_resources
  .group_by { |station| station.fetch("stationInformationStatus") }
  .transform_values(&:length)
expected_status_counts = {
  "exactPage" => 418,
  "officialContextOnly" => 18,
  "notOpenForPassengerService" => 3,
  "noCurrentPassengerService" => 5
}
fail_validation("Beijing station review statuses changed") unless status_counts == expected_status_counts
beijing_north = beijing_station_resources.find { |station| station.fetch("stationName") == "北京北" }
beijing_north_page = beijing_north&.fetch("resources", [])&.find {
  |resource| resource.fetch("kind") == "stationInformation"
}
fail_validation("Beijing North must use its exact official China Railway guide") unless
  beijing_north_page&.fetch("targetURL") ==
    "https://www.12306.cn/mormhweb/czyd_2143/bj/201001/t20100119_1582.html"
beijing_directory = beijing.fetch("resources").find do |resource|
  resource.fetch("kind") == "stationInformation" && resource.fetch("scope") == "city"
end
fail_validation("Beijing must expose the reviewed official directory fallback") unless
  beijing_directory&.fetch("targetURL") == beijing_source.fetch("sourceDirectoryURL")

runtime_swift = Dir.glob(File.join(ROOT, "JustGo", "**", "*.swift"))
  .map { |path| File.read(path, encoding: "UTF-8") }
  .join("\n")
%w[
  OfficialStationInformationProviding
  BeijingStationInformationProvider
  URLSessionConfiguration.ephemeral
  reloadIgnoringLocalAndRemoteCacheData
  maximumResponseBytes
  cacheLifetime
].each do |marker|
  fail_validation("native station-information provider is missing #{marker}") unless
    runtime_swift.include?(marker)
end
fail_validation("native provider must use the fixed Beijing station-detail path") unless
  runtime_swift.include?('"/api/guanwang/v2/getStationDetail"')

hong_kong = cities.find { |city| city.fetch("cityID") == "8100" }
hk_resources = hong_kong.fetch("resources") + hong_kong.fetch("stationResources").flat_map { |station| station.fetch("resources") }
heavy_pdfs = hk_resources.select do |resource|
  resource.fetch("format") == "pdf" && %w[systemMap locationMap stationLayout].include?(resource.fetch("kind"))
end.map { |resource| resource.fetch("targetURL") }.uniq
light_rail_pdfs = hk_resources.select { |resource| resource.fetch("kind") == "streetMap" }
  .map { |resource| resource.fetch("targetURL") }.uniq
fail_validation("Hong Kong must expose 197 unique heavy-rail PDFs") unless heavy_pdfs.length == 197
fail_validation("Hong Kong must expose 14 unique Light Rail PDFs") unless light_rail_pdfs.length == 14

binding_station_ids = JSON.parse(File.read(BINDINGS_PATH)).fetch("stations").map { |station| station.fetch("stationID") }.to_set
catalog_station_ids = hong_kong.fetch("stationResources").map { |station| station.fetch("stationID") }.to_set
unknown_station_ids = catalog_station_ids.reject { |id| binding_station_ids.include?(id) }
fail_validation("Hong Kong contains unknown canonical station IDs: #{unknown_station_ids.join(', ')}") unless unknown_station_ids.empty?
missing_station_ids = binding_station_ids.reject { |id| catalog_station_ids.include?(id) }
fail_validation("Hong Kong omits canonical station IDs: #{missing_station_ids.to_a.join(', ')}") unless missing_station_ids.empty?

%w[Central Racecourse].each do |name|
  station = hong_kong.fetch("stationResources").find { |item| item.fetch("stationNameEn") == name }
  kinds = station&.fetch("resources", [])&.map { |resource| resource.fetch("kind") }
  fail_validation("#{name} must have location and layout links") unless kinds&.include?("locationMap") && kinds.include?("stationLayout")
end
hoi_wong_road = hong_kong.fetch("stationResources").find { |item| item.fetch("stationNameEn") == "Hoi Wong Road" }
hoi_map = hoi_wong_road&.fetch("resources", [])&.find { |resource| resource.fetch("kind") == "streetMap" }
fail_validation("Hoi Wong Road must map to official Light Rail Map 1") unless hoi_map&.fetch("targetURL")&.end_with?("/lrt_01.pdf")

service_source = File.read(SERVICE_PATH)
station_method = service_source[/func externalResources\(for station: Station\).*?\n    }/m]
city_method = service_source[/func cityExternalResources\(for cityIDs: \[String\]\).*?\n    }/m]
fail_validation("station resources do not use the bundled catalog") unless station_method&.include?("officialResourceCatalog")
fail_validation("station resources still trust city-pack records") if station_method&.include?("stationRecord")
fail_validation("city resources do not use the bundled catalog") unless city_method&.include?("officialResourceCatalog")
# Station-layout coverage is gone from route scoring entirely, so the guarantee this used to make
# by pinning `officialStationMapCount: 0` is now made by there being nothing to count. It was a
# criterion no city could ever satisfy — the browser links are catalog coverage, never route
# evidence — so every route in every city lost the same points for it, permanently.
route_model_source = File.read(File.join(ROOT, "JustGo", "Models", "Transit", "Route.swift"))
fail_validation("route coverage must not carry a station-map count at all") if
  service_source.include?("officialStationMapCount") || route_model_source.include?("let officialStationMapCount")

unique_targets = all_resources.map { |resource| resource.fetch("targetURL") }.uniq.length
puts "official transit resource validation ok: cities=#{cities.length} links=#{all_resources.length} uniqueTargets=#{unique_targets} hkHeavyPDFs=#{heavy_pdfs.length} hkLightRailPDFs=#{light_rail_pdfs.length}"
