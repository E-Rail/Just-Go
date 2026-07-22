#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "lib/shanghai_station_information_importer"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(
  ROOT,
  "DataPacks",
  "sources",
  "official-resources",
  "shanghai_station_information.json"
)
NETWORK = File.join(ROOT, "JustGo", "Resources", "MetroNetworks", "3100.json")

unless ARGV == ["--refresh"]
  warn "usage: ruby Scripts/import_shanghai_station_information.rb --refresh"
  exit 64
end

catalog = ShanghaiStationInformationImporter.import(
  index: ShanghaiStationInformationImporter.fetch_index,
  network: JSON.parse(File.read(NETWORK))
)
FileUtils.mkdir_p(File.dirname(OUTPUT))
File.write(OUTPUT, JSON.pretty_generate(catalog) + "\n")
puts(
  "Shanghai station information: source=#{catalog.fetch('sourceStationCount')} " \
  "mapped=#{catalog.fetch('mappedStationCount')} " \
  "pages=#{catalog.fetch('stationPageCount')} " \
  "pageGaps=#{catalog.fetch('stationPageGapCount')} " \
  "canonicalGaps=#{catalog.fetch('canonicalCoverageGaps').length} " \
  "sourceOnly=#{catalog.fetch('sourceOnlyStationCount')}"
)
