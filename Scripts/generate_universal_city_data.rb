#!/usr/bin/env ruby
# frozen_string_literal: true

# Composes the Universal City Data Format (DataPacks/universal/) from the committed
# artifacts only — manifest, MetroNetworks, bundled city packs, the official resource
# catalog, and the rights inventory. Reading committed outputs (never importer internals)
# keeps the dependency direction clean and the result deterministic: running this twice
# must be byte-identical, which CI enforces.
#
# Format reference: DataPacks/UNIVERSAL_FORMAT.md

require "digest"
require "fileutils"
require "json"

ROOT = File.expand_path("..", __dir__)
OUTPUT_DIR = File.join(ROOT, "DataPacks/universal")
FORMAT_VERSION = 1

def load_json(relative_path)
  JSON.parse(File.read(File.join(ROOT, relative_path), encoding: "UTF-8"))
end

manifest = load_json("DataPacks/manifest.json")
catalog = load_json("DataPacks/official_transit_resources.json")
rights_inventory = load_json("DataPacks/rights_inventory.json")

manifest_by_city = manifest.fetch("cities").to_h { |city| [city.fetch("cityID"), city] }
catalog_by_city = catalog.fetch("cities").to_h { |city| [city.fetch("cityID"), city] }
unless manifest_by_city.keys.sort == catalog_by_city.keys.sort
  abort "manifest and official-resource catalog disagree on the city list"
end

rights_by_id = rights_inventory.fetch("rights").to_h { |right| [right.fetch("id"), right] }

# Deterministic: derived from the newest committed source stamp, never the wall clock.
generated_at = [manifest.fetch("generatedAt"), catalog.fetch("generatedAt")].max

FileUtils.mkdir_p(OUTPUT_DIR)
Dir[File.join(OUTPUT_DIR, "*.json")].each { |stale| File.delete(stale) }

index_cities = []

catalog_by_city.keys.sort.each do |city_id|
  manifest_entry = manifest_by_city.fetch(city_id)
  catalog_city = catalog_by_city.fetch(city_id)

  network_relative = "Just-Go/Resources/MetroNetworks/#{city_id}.json"
  network = File.file?(File.join(ROOT, network_relative)) ? load_json(network_relative) : nil
  network_document =
    if network
      {
        "version" => network.fetch("version"),
        "geometrySource" => network["geometrySource"],
        "geometryKind" => network["geometryKind"],
        "coordinateSystem" => network["coordinateSystem"],
        "attribution" => network["attribution"],
        "licenseURL" => network["licenseURL"],
        "sourceSnapshot" => network["sourceSnapshot"],
        "bounds" => network["bounds"],
        # Line geometry paths are deliberately omitted — they dominate the source files'
        # size; the ordered stationIDs sequences preserve the network topology.
        "lines" => network.fetch("lines").map do |line|
          {
            "id" => line.fetch("id"),
            "logicalLineID" => line["logicalLineID"],
            "routeReference" => line["routeReference"],
            "name" => line["name"],
            "nameEn" => line["nameEn"],
            "colorHex" => line["colorHex"],
            "stationIDs" => line.fetch("stationIDs"),
            "servicePatterns" => line["servicePatterns"]
          }
        end,
        "stations" => network.fetch("stations")
      }
    end

  bundled_resource = manifest_entry["bundledResource"]
  pack_relative = bundled_resource ? "Just-Go/Resources/#{bundled_resource}" : nil
  pack = pack_relative && File.file?(File.join(ROOT, pack_relative)) ? load_json(pack_relative) : nil

  document = {
    "formatVersion" => FORMAT_VERSION,
    "generatedAt" => generated_at,
    "city" => {
      "cityID" => city_id,
      "name" => catalog_city.fetch("name"),
      "nameEn" => catalog_city["nameEn"],
      "nameTraditional" => catalog_city["nameTraditional"]
    },
    "capabilities" => manifest_entry.fetch("capabilities"),
    "coverage" => manifest_entry.fetch("coverage"),
    "network" => network_document,
    "stationDetails" => pack ? pack.fetch("stations") : [],
    "destinationNames" => pack ? pack["destinationNames"] : nil,
    "officialResources" => {
      "reviewStatus" => catalog_city["reviewStatus"],
      "verifiedAt" => catalog_city["verifiedAt"],
      "officialDomains" => catalog_city["officialDomains"],
      "cityResources" => catalog_city.fetch("resources"),
      "stationResources" => catalog_city.fetch("stationResources"),
      "coverage" => catalog_city["coverage"]
    },
    "rights" => {
      "rightsIDs" => manifest_entry.fetch("rightsIDs"),
      "declarations" => manifest_entry.fetch("rightsIDs").map { |id| rights_by_id.fetch(id) }
    }
  }

  payload = "#{JSON.generate(document)}\n"
  file_name = "#{city_id}.json"
  File.write(File.join(OUTPUT_DIR, file_name), payload)
  index_cities << {
    "cityID" => city_id,
    "name" => catalog_city.fetch("name"),
    "nameEn" => catalog_city["nameEn"],
    "path" => file_name,
    "sizeBytes" => payload.bytesize,
    "sha256" => Digest::SHA256.hexdigest(payload),
    "hasNetwork" => !network_document.nil?,
    "lineCount" => network ? network.fetch("lines").length : 0,
    "stationCount" => network ? network.fetch("stations").length : 0
  }
end

index = {
  "formatVersion" => FORMAT_VERSION,
  "generatedAt" => generated_at,
  "cities" => index_cities
}
File.write(File.join(OUTPUT_DIR, "index.json"), "#{JSON.generate(index)}\n")

total_bytes = index_cities.sum { |city| city["sizeBytes"] }
networks = index_cities.count { |city| city["hasNetwork"] }
puts "universal city data ok: cities=#{index_cities.length} networks=#{networks} bytes=#{total_bytes}"
