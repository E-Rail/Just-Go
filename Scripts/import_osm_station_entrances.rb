#!/usr/bin/env ruby
# frozen_string_literal: true

# Vendors OpenStreetMap station entrances for the cities that ship them, and binds each entrance
# to the canonical station it serves.
#
# The raw Overpass responses are cached under .cache/osm-entrances/ (uncommitted, like the metro
# geometry cache) so a re-run is offline and free; the committed output under
# DataPacks/sources/osm-entrances/ is the small normalized form the city-pack pipeline reads, so
# CI never touches the network.
#
# Usage:
#   ruby Scripts/import_osm_station_entrances.rb              # use the cache where present
#   ruby Scripts/import_osm_station_entrances.rb --refresh    # re-fetch every city
#   ruby Scripts/import_osm_station_entrances.rb 1100 3100    # only these cities

require "fileutils"
require "json"
require_relative "lib/osm_station_entrance_importer"

ROOT = File.expand_path("..", __dir__)
CACHE_DIR = File.join(ROOT, ".cache", "osm-entrances")
OUTPUT_DIR = File.join(ROOT, "DataPacks", "sources", "osm-entrances")
NETWORK_DIR = File.join(ROOT, "JustGo", "Resources", "MetroNetworks")

# The twelve largest networks. Bounding boxes are copied from import_osm_metro_geometry.rb so the
# entrance query covers exactly the area the stations were imported from.
CITIES = {
  "1100" => { name: "Beijing", bbox: [39.60, 115.85, 40.30, 116.90] },
  "3100" => { name: "Shanghai", bbox: [30.65, 120.75, 31.90, 122.20] },
  "4401" => { name: "Guangzhou", bbox: [22.55, 112.75, 23.90, 114.20] },
  "4403" => { name: "Shenzhen", bbox: [22.35, 113.65, 22.95, 114.75] },
  "5101" => { name: "Chengdu", bbox: [30.20, 103.55, 31.10, 104.65] },
  "5000" => { name: "Chongqing", bbox: [29.30, 106.20, 29.90, 106.90] },
  "4201" => { name: "Wuhan", bbox: [30.35, 113.95, 30.85, 114.65] },
  "6101" => { name: "Xian", bbox: [34.05, 108.65, 34.55, 109.25] },
  "3301" => { name: "Hangzhou", bbox: [29.75, 119.65, 30.85, 120.95] },
  "3201" => { name: "Nanjing", bbox: [31.70, 118.45, 32.30, 119.05] },
  "1200" => { name: "Tianjin", bbox: [38.85, 116.80, 39.45, 117.80] },
  "3205" => { name: "Suzhou", bbox: [31.10, 120.35, 31.55, 120.95] }
}.freeze

refresh = ARGV.delete("--refresh")
selected = ARGV.empty? ? CITIES.keys : ARGV
unknown = selected - CITIES.keys
unless unknown.empty?
  warn "unknown city IDs: #{unknown.join(", ")}"
  exit 64
end

FileUtils.mkdir_p(CACHE_DIR)
FileUtils.mkdir_p(OUTPUT_DIR)

totals = Hash.new(0)
selected.each do |city_id|
  city = CITIES.fetch(city_id)
  cache_path = File.join(CACHE_DIR, "#{city_id}.json")

  payload =
    if File.file?(cache_path) && !refresh
      JSON.parse(File.read(cache_path))
    else
      warn "fetching #{city_id} #{city.fetch(:name)}…"
      fetched = OSMStationEntranceImporter.fetch(
        city.fetch(:bbox),
        logger: ->(message) { warn message }
      )
      File.write(cache_path, JSON.generate(fetched))
      # Overpass is free and shared; pause between cities rather than hammering it.
      sleep 5
      fetched
    end

  entrances = OSMStationEntranceImporter.normalize(payload)
  network = JSON.parse(File.read(File.join(NETWORK_DIR, "#{city_id}.json")))
  document = OSMStationEntranceImporter.document(
    city_id: city_id,
    entrances: entrances,
    network: network
  )
  File.write(File.join(OUTPUT_DIR, "#{city_id}.json"), "#{JSON.pretty_generate(document)}\n")

  stats = document.fetch("stats")
  totals["entrances"] += stats.fetch("entranceCount")
  totals["bound"] += stats.fetch("boundCount")
  totals["stations"] += stats.fetch("stationsWithEntrances")
  puts(
    format(
      "%<id>s %<name>-10s entrances=%<entrances>5d bound=%<bound>5d " \
      "unmatched=%<unmatched>4d ambiguous=%<ambiguous>3d stations=%<stations>4d/%<total>4d",
      id: city_id, name: city.fetch(:name),
      entrances: stats.fetch("entranceCount"), bound: stats.fetch("boundCount"),
      unmatched: stats.fetch("unmatchedCount"), ambiguous: stats.fetch("ambiguousCount"),
      stations: stats.fetch("stationsWithEntrances"), total: stats.fetch("networkStationCount")
    )
  )
end

puts(
  "OSM station entrances: cities=#{selected.length} entrances=#{totals["entrances"]} " \
  "bound=#{totals["bound"]} stationsWithEntrances=#{totals["stations"]}"
)
