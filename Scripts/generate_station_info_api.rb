#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates StationInfoAPI/directory/directory.json — the developer-facing index that maps
# every canonical station ID to the sources that cover it and the identifiers each source
# needs. It is derived from the reviewed per-city catalogs under
# DataPacks/sources/official-resources, so it carries only station IDs, names, aliases and
# page URLs (the link-only scope), never operator content.
#
# Deterministic: re-running produces byte-identical output. `--check` re-derives in memory and
# fails if the committed file has drifted, without writing.
#
# Usage:
#   ruby Scripts/generate_station_info_api.rb            # write
#   ruby Scripts/generate_station_info_api.rb --check    # verify committed file is current

require "json"

module StationInfoAPIGenerator
  ROOT = File.expand_path("..", __dir__)
  SOURCES_DIR = File.join(ROOT, "DataPacks", "sources", "official-resources")
  OUTPUT = File.join(ROOT, "StationInfoAPI", "directory", "directory.json")
  # The app consumes the published contract, exactly like a third-party developer would, rather
  # than reaching into DataPacks. It bundles a mirror of the directory (routing) and the source
  # registry (which cities are served, and how). Both are written from the same source of truth
  # here so they cannot drift; CI diff-checks the mirror.
  AUTHORED_SOURCES = File.join(ROOT, "StationInfoAPI", "sources", "sources.json")
  BUNDLE_DIR = File.join(ROOT, "JustGo", "Resources", "StationInfo")
  BUNDLED_DIRECTORY = File.join(BUNDLE_DIR, "directory.json")
  BUNDLED_SOURCES = File.join(BUNDLE_DIR, "sources.json")

  module_function

  def catalog(name)
    JSON.parse(File.read(File.join(SOURCES_DIR, name)))
  end

  # Each builder returns [stationID, entry-fragment] pairs; entry-fragment carries the station's
  # display fields plus its single source reference. Fragments for the same station ID (which
  # cannot happen across cities today, but the merge keeps the format honest) union their sources.
  def beijing_entries
    catalog("beijing_station_information.json").fetch("stations").map do |station|
      [
        station.fetch("stationID"),
        display(station).merge(
          "sources" => {
            "beijingSubwayOnline" => {
              "externalStationID" => station.fetch("externalStationID"),
              "sourcePageURL" => station.fetch("sourcePageURL")
            }
          }
        )
      ]
    end
  end

  def shanghai_entries
    catalog("shanghai_station_information.json").fetch("stations").map do |station|
      [
        station.fetch("stationID"),
        display(station).merge(
          "sources" => {
            "shanghaiMetroOnline" => {
              "externalStationID" => station.fetch("externalStationID"),
              "lineStationIDs" => station.fetch("lineStationIDs"),
              "sourcePageURL" => station.fetch("sourcePageURL")
            }
          }
        )
      ]
    end
  end

  def hong_kong_entries
    catalog("hong_kong_station_bindings.json").fetch("stations").map do |station|
      [
        station.fetch("stationID"),
        display(station).merge(
          "sources" => {
            "hongKongGovernment" => {
              "liveArrivalReferences" => station.fetch("liveArrivalReferences")
            }
          }
        )
      ]
    end
  end

  def display(station)
    entry = { "name" => station.fetch("stationName") }
    name_en = station["stationNameEn"].to_s.strip
    entry["nameEn"] = name_en unless name_en.empty? || name_en == entry["name"]
    aliases = Array(station["aliases"]).map(&:to_s).reject(&:empty?)
    entry["aliases"] = aliases unless aliases.empty?
    entry
  end

  def build
    merged = {}
    (beijing_entries + shanghai_entries + hong_kong_entries).each do |station_id, fragment|
      existing = merged[station_id]
      if existing
        existing.fetch("sources").merge!(fragment.fetch("sources"))
      else
        merged[station_id] = fragment
      end
    end

    stations = merged.sort.to_h
    used_sources = stations.values.flat_map { |entry| entry.fetch("sources").keys }.uniq.sort

    {
      "schemaVersion" => 1,
      "generatedBy" => "Scripts/generate_station_info_api.rb",
      "wireSchema" => "../schema/station-information.schema.json",
      "sourceRegistry" => "../sources/sources.json",
      "sources" => used_sources,
      "stationCount" => stations.length,
      "stations" => stations
    }
  end

  def serialize
    JSON.pretty_generate(build) + "\n"
  end

  # The two files the app bundles: the routing directory and a verbatim copy of the source
  # registry. Keyed by destination path so `write!` and `check!` share one definition.
  def bundle_outputs
    {
      BUNDLED_DIRECTORY => serialize,
      BUNDLED_SOURCES => File.read(AUTHORED_SOURCES)
    }
  end

  def write!
    File.write(OUTPUT, serialize)
    require "fileutils"
    FileUtils.mkdir_p(BUNDLE_DIR)
    bundle_outputs.each { |path, content| File.write(path, content) }
    document = build
    warn(
      "Station info directory: stations=#{document.fetch('stationCount')} " \
      "sources=#{document.fetch('sources').join(', ')}; bundled mirror written"
    )
  end

  def check!
    stale = []
    stale << OUTPUT unless (File.file?(OUTPUT) ? File.read(OUTPUT) : nil) == serialize
    bundle_outputs.each do |path, content|
      stale << path unless (File.file?(path) ? File.read(path) : nil) == content
    end
    if stale.empty?
      warn "Station info directory and bundled mirror are current."
      true
    else
      warn "Station info API is stale (#{stale.map { |p| p.delete_prefix("#{ROOT}/") }.join(', ')}); " \
           "run: ruby Scripts/generate_station_info_api.rb"
      false
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--check"]
    exit(StationInfoAPIGenerator.check! ? 0 : 1)
  elsif ARGV.empty?
    StationInfoAPIGenerator.write!
  else
    warn "usage: ruby Scripts/generate_station_info_api.rb [--check]"
    exit 64
  end
end
