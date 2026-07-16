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
%w[NSLocationWhenInUseUsageDescription NSCameraUsageDescription].each do |key|
  errors << "JustGo-Info.plist is missing #{key}" unless info_plist.include?("<key>#{key}</key>")
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
  hasIndoorMapsURL
  loadGenerationMatches
  pruneSupersededVersions
].each do |marker|
  errors << "city-pack runtime policy is missing #{marker}" unless policy_source.include?(marker)
end
errors << "remote packs must reject unproven service status" unless policy_source.include?("station.serviceStatus == nil")
errors << "schema-v2 manifests must reject indoor downloads" unless policy_source.include?("!hasIndoorMapsURL")

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

project = read.call("JustGo.xcodeproj/project.pbxproj")
%w[BundledCityPacks LicensedMedia PrivacyInfo.xcprivacy THIRD_PARTY_NOTICES.md official_transit_resources.json].each do |resource|
  errors << "Xcode resources are missing #{resource}" unless project.include?(resource)
end
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

puts "runtime-data-policy validation ok: configured_origins=0 runtime_web_links=#{actual_web_literals.length} remote_pack_callers=1"
