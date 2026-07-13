#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

ROOT = File.expand_path("..", __dir__)
PACK_DIR = File.join(ROOT, "DataPacks", "packs", "1100", "beijing-official-20260527")
FRAGMENT_DIR = File.join(PACK_DIR, "indoor")
OUTPUT_PATH = File.join(PACK_DIR, "indoor_maps.json")
MANIFEST_PATH = File.join(ROOT, "DataPacks", "manifest.json")
NETWORK_PATH = File.join(ROOT, "JustGo", "Resources", "MetroNetworks", "1100.json")
CITY_PACK_PATH = File.join(PACK_DIR, "city_pack.json")

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => error
  abort "#{path} is not valid JSON: #{error.message}"
end

def immediate_neighbor_toward(line, station_id, target_id)
  return nil if station_id.nil? || target_id.nil? || station_id == target_id

  Array(line["servicePatterns"]).each do |pattern|
    next unless pattern.is_a?(Array)

    is_loop = pattern.length > 2 && pattern.first == pattern.last
    core = is_loop ? pattern[0...-1] : pattern
    next if core.length < 2

    station_index = core.index(station_id)
    target_index = core.index(target_id)
    next unless station_index && target_index

    if is_loop
      forward_steps = (target_index - station_index) % core.length
      backward_steps = (station_index - target_index) % core.length
      return core[(station_index + (forward_steps <= backward_steps ? 1 : -1)) % core.length]
    end
    return core[station_index + (target_index > station_index ? 1 : -1)]
  end
  nil
end

def build_indoor_maps
  network = load_json(NETWORK_PATH)
  station_names_by_id = network.fetch("stations").to_h { |station| [station.fetch("id"), station.fetch("name")] }
  lines_by_id = network.fetch("lines").to_h { |line| [line.fetch("id"), line] }
  city_pack = load_json(CITY_PACK_PATH)
  pack_stations_by_name = city_pack.fetch("stations").to_h { |station| [station.fetch("stationName"), station] }

  fragments = Dir.glob(File.join(FRAGMENT_DIR, "*.json")).sort.map do |path|
    indoor_map = load_json(path)
    indoor_map["coverageMode"] ||= indoor_map.fetch("edges", []).empty? ? "platformCheckpoints" : "transferPaths"
    station_id = indoor_map.fetch("stationID")
    expected_id = File.basename(path, ".json")
    abort "#{path}: stationID must match its filename" unless station_id == expected_id

    station_name = station_names_by_id[station_id]
    abort "#{path}: stationID is absent from the Beijing network" unless station_name
    provenance = indoor_map["provenance"]
    if provenance
      matching_map = Array(pack_stations_by_name.dig(station_name, "stationMaps")).find do |station_map|
        asset_path = File.join(PACK_DIR, station_map.fetch("assetURL"))
        File.file?(asset_path) && Digest::SHA256.file(asset_path).hexdigest == provenance["sourceContentSHA256"]
      end
      abort "#{path}: provenance digest does not match a station-map asset" unless matching_map
      provenance["sourceURL"] = matching_map.fetch("sourceURL")
    end
    platform_counts_by_line = indoor_map.fetch("nodes")
      .select { |node| node["kind"] == "platform" && node["lineID"] }
      .group_by { |node| node["lineID"] }
      .transform_values(&:length)
    indoor_map.fetch("nodes").each do |node|
      next unless node["kind"] == "platform" && node["lineID"]

      line = lines_by_id[node.fetch("lineID")]
      abort "#{path}: platform #{node['id']} has an unknown lineID" unless line
      neighbors = Array(line["servicePatterns"]).flat_map do |pattern|
        pattern.each_cons(2).flat_map do |left, right|
          left == station_id ? [right] : right == station_id ? [left] : []
        end
      end.uniq
      %w[arrivalFromStationIDs departureTowardStationIDs].each do |key|
        node[key] = if platform_counts_by_line[node["lineID"]] == 1
          neighbors
        else
          Array(node[key]).map do |target_id|
            next target_id if neighbors.include?(target_id)

            immediate_neighbor_toward(line, station_id, target_id) ||
              abort("#{path}: platform #{node['id']} #{key} target is absent from its line")
          end.uniq
        end
      end
    end
    { "stationName" => station_name, "indoorMap" => indoor_map }
  end

  duplicates = fragments.group_by { |item| item.fetch("stationName") }.select { |_name, items| items.length > 1 }
  abort "duplicate indoor-map fragments: #{duplicates.keys.join(', ')}" unless duplicates.empty?

  output = {
    "cityID" => network.fetch("cityID"),
    "version" => "beijing-official-20260527",
    "stations" => fragments.sort_by { |item| item.fetch("stationName") }
  }
  output_data = JSON.pretty_generate(output) + "\n"
  File.write(OUTPUT_PATH, output_data)

  manifest = load_json(MANIFEST_PATH)
  city = manifest.fetch("cities").find { |item| item["cityID"] == network.fetch("cityID") }
  abort "Beijing is absent from DataPacks/manifest.json" unless city
  city["indoorMapsSizeBytes"] = output_data.bytesize
  city["indoorMapsSHA256"] = Digest::SHA256.hexdigest(output_data)
  manifest_data = JSON.pretty_generate(manifest).gsub(/\[\n\s*\]/, "[]") + "\n"
  File.write(MANIFEST_PATH, manifest_data)

  puts "built indoor maps: stations=#{fragments.length} bytes=#{output_data.bytesize}"
end

build_indoor_maps if $PROGRAM_NAME == __FILE__
