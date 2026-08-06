#!/usr/bin/env ruby
# frozen_string_literal: true

# Cross-checks DataPacks/universal/ (the committed Universal City Data Format) against its
# committed sources: every manifest city has exactly one universal file, the index's
# size/sha256 entries match the bytes on disk, and each document's network, station
# details, official resources, capabilities, coverage, and rights agree with the manifest,
# MetroNetworks assets, bundled city packs, catalog, and rights inventory they were
# composed from. Line geometry paths must stay omitted.

require "digest"
require "json"

ROOT = File.expand_path("..", __dir__)
UNIVERSAL_DIR = File.join(ROOT, "DataPacks/universal")
FORMAT_VERSION = 1

errors = []

def load_json(relative_path)
  JSON.parse(File.read(File.join(ROOT, relative_path), encoding: "UTF-8"))
end

manifest = load_json("DataPacks/manifest.json")
catalog = load_json("DataPacks/official_transit_resources.json")
rights_inventory = load_json("DataPacks/rights_inventory.json")
index = load_json("DataPacks/universal/index.json")

manifest_by_city = manifest.fetch("cities").to_h { |city| [city.fetch("cityID"), city] }
catalog_by_city = catalog.fetch("cities").to_h { |city| [city.fetch("cityID"), city] }
rights_by_id = rights_inventory.fetch("rights").to_h { |right| [right.fetch("id"), right] }

errors << "index formatVersion must be #{FORMAT_VERSION}" unless index["formatVersion"] == FORMAT_VERSION

index_by_city = index.fetch("cities").to_h { |city| [city.fetch("cityID"), city] }
unless index_by_city.keys.sort == manifest_by_city.keys.sort
  errors << "index city list does not match the manifest"
end
unless index.fetch("cities").map { |city| city.fetch("cityID") } == index_by_city.keys.sort
  errors << "index cities must be sorted by cityID"
end

disk_files = Dir[File.join(UNIVERSAL_DIR, "*.json")].map { |path| File.basename(path) }.sort
expected_files = (index_by_city.keys.map { |city_id| "#{city_id}.json" } + ["index.json"]).sort
unless disk_files == expected_files
  errors << "universal directory contents do not match the index (#{(disk_files - expected_files) + (expected_files - disk_files)})"
end

network_total = 0
station_detail_total = 0

index_by_city.each do |city_id, index_entry|
  path = File.join(UNIVERSAL_DIR, index_entry.fetch("path"))
  unless File.file?(path)
    errors << "missing universal file for #{city_id}"
    next
  end
  payload = File.read(path, encoding: "UTF-8")
  errors << "#{city_id}: sizeBytes drifted from the file" unless payload.bytesize == index_entry["sizeBytes"]
  errors << "#{city_id}: sha256 drifted from the file" unless Digest::SHA256.hexdigest(payload) == index_entry["sha256"]
  errors << "#{city_id}: file must end with a single trailing newline" unless payload.end_with?("\n") && !payload.end_with?("\n\n")
  errors << "#{city_id}: file must be minified" if payload.lines.length > 1

  document = JSON.parse(payload)
  manifest_entry = manifest_by_city.fetch(city_id)
  catalog_city = catalog_by_city.fetch(city_id)

  errors << "#{city_id}: formatVersion must be #{FORMAT_VERSION}" unless document["formatVersion"] == FORMAT_VERSION
  errors << "#{city_id}: generatedAt must match the index" unless document["generatedAt"] == index["generatedAt"]
  errors << "#{city_id}: city identity drifted from the catalog" unless
    document.dig("city", "cityID") == city_id &&
    document.dig("city", "name") == catalog_city["name"] &&
    document.dig("city", "nameEn") == catalog_city["nameEn"]
  errors << "#{city_id}: capabilities drifted from the manifest" unless document["capabilities"] == manifest_entry["capabilities"]
  errors << "#{city_id}: coverage drifted from the manifest" unless document["coverage"] == manifest_entry["coverage"]

  network_path = File.join(ROOT, "Just-Go/Resources/MetroNetworks/#{city_id}.json")
  if File.file?(network_path)
    network = JSON.parse(File.read(network_path, encoding: "UTF-8"))
    universal_network = document["network"]
    if universal_network.nil?
      errors << "#{city_id}: network missing despite a MetroNetworks asset"
    else
      network_total += 1
      errors << "#{city_id}: network stations drifted from MetroNetworks" unless
        universal_network["stations"] == network["stations"]
      errors << "#{city_id}: line count drifted from MetroNetworks" unless
        universal_network["lines"].length == network["lines"].length
      universal_network["lines"].each_with_index do |line, line_index|
        errors << "#{city_id}: line geometry paths must be omitted" if line.key?("paths")
        source_line = network["lines"][line_index]
        errors << "#{city_id}: line #{line["id"]} identity drifted" unless
          line["id"] == source_line["id"] &&
          line["name"] == source_line["name"] &&
          line["colorHex"] == source_line["colorHex"] &&
          line["stationIDs"] == source_line["stationIDs"]
      end
      universal_network["stations"].each do |station|
        unless station["id"].to_s.match?(/\A\h{16}\z/)
          errors << "#{city_id}: station ID #{station["id"]} is not a 16-hex identifier"
          break
        end
      end
      errors << "#{city_id}: index lineCount drifted" unless index_entry["lineCount"] == network["lines"].length
      errors << "#{city_id}: index stationCount drifted" unless index_entry["stationCount"] == network["stations"].length
      errors << "#{city_id}: index hasNetwork drifted" unless index_entry["hasNetwork"] == true
    end
  else
    errors << "#{city_id}: network must be null without a MetroNetworks asset" unless document["network"].nil?
    errors << "#{city_id}: index hasNetwork drifted" unless index_entry["hasNetwork"] == false
  end

  bundled_resource = manifest_entry["bundledResource"]
  pack_path = bundled_resource ? File.join(ROOT, "Just-Go/Resources", bundled_resource) : nil
  if pack_path && File.file?(pack_path)
    pack = JSON.parse(File.read(pack_path, encoding: "UTF-8"))
    station_detail_total += document.fetch("stationDetails").length
    errors << "#{city_id}: stationDetails drifted from the bundled pack" unless
      document["stationDetails"] == pack["stations"]
    errors << "#{city_id}: destinationNames drifted from the bundled pack" unless
      document["destinationNames"] == pack["destinationNames"]
  else
    errors << "#{city_id}: stationDetails must be empty without a bundled pack" unless
      document["stationDetails"] == []
  end

  errors << "#{city_id}: station resources drifted from the catalog" unless
    document.dig("officialResources", "stationResources") == catalog_city["stationResources"]
  errors << "#{city_id}: city resources drifted from the catalog" unless
    document.dig("officialResources", "cityResources") == catalog_city["resources"]

  rights_ids = document.dig("rights", "rightsIDs")
  errors << "#{city_id}: rightsIDs drifted from the manifest" unless rights_ids == manifest_entry["rightsIDs"]
  expected_declarations = (rights_ids || []).map { |id| rights_by_id[id] }
  if expected_declarations.any?(&:nil?)
    errors << "#{city_id}: rightsIDs reference unknown rights inventory entries"
  elsif document.dig("rights", "declarations") != expected_declarations
    errors << "#{city_id}: rights declarations drifted from the inventory"
  end
end

unless errors.empty?
  warn "universal-city-data validation failed:"
  errors.each { |error| warn "- #{error}" }
  exit 1
end

puts "universal-city-data validation ok: cities=#{index_by_city.length} networks=#{network_total} station_details=#{station_detail_total}"
