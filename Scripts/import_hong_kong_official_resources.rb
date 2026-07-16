#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "lib/official_transit_resource_importer"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(ROOT, "DataPacks", "sources", "official-resources", "hong_kong_index.json")
BINDINGS = File.join(ROOT, "DataPacks", "sources", "official-resources", "hong_kong_station_bindings.json")

unless ARGV == ["--refresh"]
  warn "usage: ruby Scripts/import_hong_kong_official_resources.rb --refresh"
  exit 64
end

system_html = OfficialTransitResourceImporter.fetch(OfficialTransitResourceImporter::SYSTEM_INDEX_URL)
light_rail_html = OfficialTransitResourceImporter.fetch(OfficialTransitResourceImporter::LIGHT_RAIL_INDEX_URL)
catalog = OfficialTransitResourceImporter.import(
  system_html: system_html,
  light_rail_html: light_rail_html,
  station_bindings_path: BINDINGS
)

FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate(catalog) + "\n")
puts "Hong Kong official-resource index: heavyRail=#{catalog.fetch('heavyRailStations').length} lightRailMaps=#{catalog.fetch('lightRailMaps').length}"
