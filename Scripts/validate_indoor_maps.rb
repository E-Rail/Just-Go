#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/oss_data_validators"

ROOT = File.expand_path("..", __dir__)
PACK_PATTERN = File.join(ROOT, "Just-Go", "Resources", "BundledCityPacks", "*.json")
FORBIDDEN_STATION_FIELDS = %w[
  indoorMap indoorMaps platformCheckpoints lineCoverageGaps transferPaths
  boardingZoneHints doorGuidance verifiedTransferContexts
].freeze

def fail_with(message)
  warn "indoor-map validation failed: #{message}"
  exit 1
end

forbidden_files = Dir.glob(File.join(ROOT, "DataPacks", "**", "indoor_maps.json"))
forbidden_files.concat(Dir.glob(File.join(ROOT, "Just-Go", "Resources", "**", "indoor_maps.json")))
forbidden_files.concat(Dir.glob(File.join(ROOT, "DataPacks", "**", "indoor", "**", "*")))
forbidden_files.concat(Dir.glob(File.join(ROOT, "DataPacks", "**", "station_maps", "**", "*")))
forbidden_files.select! { |path| File.file?(path) }
fail_with("stale traced indoor data remains: #{forbidden_files.join(", ")}") unless forbidden_files.empty?

project = File.read(File.join(ROOT, "Just-Go.xcodeproj", "project.pbxproj"), encoding: "UTF-8")
fail_with("Xcode still references indoor_maps.json") if project.include?("indoor_maps.json")

pack_paths = Dir.glob(PACK_PATTERN).sort
expected_packs = OSSDataValidators::BUNDLED_CITY_IDS
found_packs = pack_paths.map { |path| File.basename(path, ".json") }.sort
unless found_packs == expected_packs
  fail_with("expected the reviewed bundled packs #{expected_packs.join(", ")}, found #{found_packs.join(", ")}")
end

station_count = 0
pack_paths.each do |path|
  pack = JSON.parse(File.read(path, encoding: "UTF-8"))
  coverage = pack.fetch("coverage").fetch("verifiedTransferContexts")
  fail_with("#{pack.fetch("cityID")} claims verified transfer coverage") unless coverage.fetch("covered").zero?

  pack.fetch("stations").each do |station|
    station_count += 1
    FORBIDDEN_STATION_FIELDS.each do |field|
      value = station[field]
      next if value.nil? || value == [] || value == {}

      fail_with("#{pack.fetch("cityID")} #{station.fetch("stationID")} contains unverified #{field}")
    end
    %w[platformHints interchangeHints].each do |field|
      fail_with("#{pack.fetch("cityID")} #{station.fetch("stationID")} contains unverified #{field}") unless Array(station[field]).empty?
    end
  end
end

manifest = JSON.parse(File.read(File.join(ROOT, "DataPacks", "manifest.json"), encoding: "UTF-8"))
manifest.fetch("cities").each do |city|
  coverage = city.fetch("coverage").fetch("verifiedTransferContexts")
  fail_with("#{city.fetch("cityID")} manifest claims verified transfer coverage") unless coverage.fetch("covered").zero?
  fail_with("#{city.fetch("cityID")} exposes an indoor download") if city["indoorMapsDownloadURL"]
end

puts "indoor-map validation ok: packs=#{pack_paths.length} stations=#{station_count} verified_contexts=0 data_files=0"
