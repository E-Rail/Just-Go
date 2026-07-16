#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"
require "uri"
require_relative "lib/official_transit_resource_catalog"

ROOT = File.expand_path("..", __dir__)
CATALOG_PATH = File.join(ROOT, "DataPacks", "official_transit_resources.json")
BINDINGS_PATH = File.join(ROOT, "DataPacks", "sources", "official-resources", "hong_kong_station_bindings.json")
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
  travel = %w[serviceStatus journeyPlanner timetable fareInformation].sum { |kind| grouped.fetch(kind, []).length }
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
fail_validation("route coverage still trusts pack or hyperlink station maps") unless service_source.include?("officialStationMapCount: 0")

unique_targets = all_resources.map { |resource| resource.fetch("targetURL") }.uniq.length
puts "official transit resource validation ok: cities=#{cities.length} links=#{all_resources.length} uniqueTargets=#{unique_targets} hkHeavyPDFs=#{heavy_pdfs.length} hkLightRailPDFs=#{light_rail_pdfs.length}"
