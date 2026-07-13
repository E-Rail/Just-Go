#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
MANIFEST_PATH = File.join(DATA_PACKS_DIR, "manifest.json")
NETWORKS_DIR = File.join(ROOT, "JustGo", "Resources", "MetroNetworks")

NODE_KINDS = %w[platform exit gate elevator escalator stairs corridor concourse].freeze
TRAVERSAL_KINDS = %w[walkway stairs escalator elevator gate].freeze
INSTRUCTION_ACTIONS = %w[continueStraight turnLeft turnRight followSigns takeStairs takeEscalator takeElevator].freeze
REVIEW_STATUSES = %w[draft diagramReviewed onSiteVerified].freeze
ASSET_USAGE_STATUSES = %w[approvedEmbedded approvedRemote metadataOnly blocked reviewRequired].freeze
COVERAGE_MODES = %w[platformCheckpoints transferPaths].freeze
BOARDING_ZONES = %w[front middle rear].freeze
LINE_COVERAGE_GAP_REASONS = %w[sourceDoesNotDepictLine].freeze
DATA_CONFIDENCES = %w[official mapKit communityVerified personal estimated sourcePending unavailable unknown].freeze

def fail_with(message)
  warn "indoor-map validation failed: #{message}"
  exit 1
end

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => error
  fail_with("#{path} is not valid JSON: #{error.message}")
end

def validate_coordinate(label, coordinate)
  fail_with("#{label} coordinate is missing") unless coordinate.is_a?(Hash)
  %w[x y].each do |axis|
    value = coordinate[axis]
    fail_with("#{label} coordinate.#{axis} must be numeric") unless value.is_a?(Numeric)
    fail_with("#{label} coordinate.#{axis} must be within 0...1") unless value.between?(0.0, 1.0)
  end
end

def adjacent_station_ids(line, station_id)
  pairs = Array(line["servicePatterns"]).flat_map { |pattern| pattern.each_cons(2).to_a }
  pairs = Array(line["stationIDs"]).each_cons(2).to_a if pairs.empty?
  pairs.each_with_object([]) do |(left, right), result|
    result << right if left == station_id
    result << left if right == station_id
  end.uniq
end

def platforms_all_reachable?(nodes, edges)
  platform_ids = nodes.select { |node| node["kind"] == "platform" }.map { |node| node["id"] }
  return true if platform_ids.length < 2

  adjacency = Hash.new { |hash, key| hash[key] = [] }
  edges.each do |edge|
    adjacency[edge["fromNodeID"]] << edge["toNodeID"]
    adjacency[edge["toNodeID"]] << edge["fromNodeID"] if edge["isBidirectional"]
  end
  visited = { platform_ids.first => true }
  queue = [platform_ids.first]
  until queue.empty?
    adjacency[queue.shift].each do |neighbor|
      next if visited[neighbor]

      visited[neighbor] = true
      queue << neighbor
    end
  end
  platform_ids.all? { |id| visited[id] }
end

def validate_provenance(label, provenance, station_map, pack_dir)
  fail_with("#{label} provenance is required for schema v2") unless provenance.is_a?(Hash)
  fail_with("#{label} provenance.sourceURL must match the station-map source") unless provenance["sourceURL"] == station_map["sourceURL"]
  sha = provenance["sourceContentSHA256"].to_s
  fail_with("#{label} provenance SHA-256 is malformed") unless sha.match?(/\A[0-9a-f]{64}\z/i)
  fail_with("#{label} has unknown reviewStatus") unless REVIEW_STATUSES.include?(provenance["reviewStatus"])
  fail_with("#{label} has unknown assetUsageStatus") unless ASSET_USAGE_STATUSES.include?(provenance["assetUsageStatus"])
  fail_with("#{label} provenance.notes must be an array") unless provenance["notes"].is_a?(Array)

  asset_path = File.expand_path(station_map.fetch("assetURL"), pack_dir)
  fail_with("#{label} station-map asset escapes its pack") unless asset_path.start_with?(pack_dir + File::SEPARATOR)
  fail_with("#{label} station-map asset is missing: #{asset_path}") unless File.file?(asset_path)
  actual_sha = Digest::SHA256.file(asset_path).hexdigest
  fail_with("#{label} provenance SHA-256 does not match the station-map asset") unless sha.casecmp(actual_sha).zero?
end

def validate_indoor_map(label, indoor_map, station, lines_by_id, station_map, pack_dir)
  station_id = indoor_map["stationID"]
  fail_with("#{label} stationID must match the canonical network ID") unless station_id == station["id"]
  schema_version = indoor_map["schemaVersion"] || 1
  coverage_mode = indoor_map["coverageMode"] || (Array(indoor_map["edges"]).empty? ? "platformCheckpoints" : "transferPaths")
  if schema_version >= 2
    fail_with("#{label} has unknown coverageMode #{coverage_mode}") unless COVERAGE_MODES.include?(coverage_mode)
    fail_with("#{label} has unknown confidence #{indoor_map['confidence']}") unless DATA_CONFIDENCES.include?(indoor_map["confidence"])
    validate_provenance(label, indoor_map["provenance"], station_map, pack_dir)
    if indoor_map.dig("provenance", "reviewStatus") != "onSiteVerified" && indoor_map["confidence"] == "official"
      fail_with("#{label} cannot claim official confidence without on-site verification")
    end
  end

  levels = indoor_map["levels"]
  fail_with("#{label} levels must be a non-empty array") unless levels.is_a?(Array) && !levels.empty?
  level_ids = levels.map { |level| level["id"] }
  fail_with("#{label} levels has duplicate ids") if level_ids.uniq.length != level_ids.length
  ordinals = levels.map { |level| level["ordinal"] }
  fail_with("#{label} levels must be sorted by ordinal") unless ordinals == ordinals.sort

  nodes = indoor_map["nodes"]
  fail_with("#{label} nodes must be a non-empty array") unless nodes.is_a?(Array) && !nodes.empty?
  node_ids = nodes.map { |node| node["id"] }
  fail_with("#{label} nodes has duplicate ids") if node_ids.uniq.length != node_ids.length
  node_id_set = node_ids.to_h { |id| [id, true] }
  platform_line_ids = []

  nodes.each do |node|
    fail_with("#{label} node #{node['id']} has unknown kind #{node['kind']}") unless NODE_KINDS.include?(node["kind"])
    fail_with("#{label} node #{node['id']} references unknown level #{node['levelID']}") unless level_ids.include?(node["levelID"])
    validate_coordinate("#{label} node #{node['id']}", node["coordinate"])
    next unless schema_version >= 2 && node["kind"] == "platform"

    line_id = node["lineID"]
    line = lines_by_id[line_id]
    fail_with("#{label} platform #{node['id']} has an unknown lineID") unless line
    fail_with("#{label} platform #{node['id']} line does not serve this station") unless Array(station["lineIDs"]).include?(line_id)
    fail_with("#{label} platform #{node['id']} is missing platformID") if node["platformID"].to_s.empty?
    fail_with("#{label} platform #{node['id']} needs recognitionAliases") if Array(node["recognitionAliases"]).empty?
    platform_line_ids << line_id

    neighbors = adjacent_station_ids(line, station_id)
    %w[arrivalFromStationIDs departureTowardStationIDs].each do |key|
      invalid = Array(node[key]) - neighbors
      fail_with("#{label} platform #{node['id']} #{key} has non-adjacent IDs: #{invalid.join(', ')}") unless invalid.empty?
    end
  end

  if schema_version >= 2
    raw_coverage_gaps = indoor_map["lineCoverageGaps"]
    fail_with("#{label} lineCoverageGaps must be an array") unless raw_coverage_gaps.nil? || raw_coverage_gaps.is_a?(Array)
    coverage_gaps = Array(raw_coverage_gaps)
    coverage_gaps.each do |gap|
      fail_with("#{label} line coverage gap must be an object") unless gap.is_a?(Hash)
    end
    gap_line_ids = coverage_gaps.map { |gap| gap["lineID"] }
    fail_with("#{label} lineCoverageGaps has duplicate line IDs") if gap_line_ids.uniq.length != gap_line_ids.length
    fail_with("#{label} transfer-path coverage cannot contain line coverage gaps") if coverage_mode == "transferPaths" && !coverage_gaps.empty?

    coverage_gaps.each do |gap|
      line_id = gap["lineID"]
      fail_with("#{label} line coverage gap has an unknown lineID") unless lines_by_id[line_id]
      fail_with("#{label} line coverage gap does not serve this station") unless Array(station["lineIDs"]).include?(line_id)
      fail_with("#{label} line coverage gap overlaps a platform checkpoint") if platform_line_ids.include?(line_id)
      fail_with("#{label} line coverage gap has an unknown reason") unless LINE_COVERAGE_GAP_REASONS.include?(gap["reason"])
      fail_with("#{label} line coverage gap needs a non-empty note") if gap["note"].to_s.strip.empty?
    end

    missing_lines = Array(station["lineIDs"]) - platform_line_ids.uniq - gap_line_ids
    fail_with("#{label} is missing platform checkpoints or explicit coverage gaps for lines: #{missing_lines.join(', ')}") unless missing_lines.empty?
  end

  edges = indoor_map["edges"]
  fail_with("#{label} edges must be an array") unless edges.is_a?(Array)
  edge_ids = edges.map { |edge| edge["id"] }
  fail_with("#{label} edges has duplicate ids") if edge_ids.uniq.length != edge_ids.length
  edges.each do |edge|
    %w[fromNodeID toNodeID].each do |key|
      fail_with("#{label} edge #{edge['id']} references unknown node #{edge[key]}") unless node_id_set[edge[key]]
    end
    fail_with("#{label} edge #{edge['id']} distanceMeters must be positive") unless edge["distanceMeters"].is_a?(Numeric) && edge["distanceMeters"].positive?
    fail_with("#{label} edge #{edge['id']} typicalSeconds must be positive") unless edge["typicalSeconds"].is_a?(Numeric) && edge["typicalSeconds"].positive?
    next unless schema_version >= 2

    fail_with("#{label} edge #{edge['id']} has unknown traversalKind") unless TRAVERSAL_KINDS.include?(edge["traversalKind"])
    Array(edge["shape"]).each { |point| validate_coordinate("#{label} edge #{edge['id']} shape", point) }
    %w[forwardInstruction reverseInstruction].each do |key|
      instruction = edge[key]
      next unless instruction

      fail_with("#{label} edge #{edge['id']} #{key} has unknown action") unless INSTRUCTION_ACTIONS.include?(instruction["action"])
      landmark_id = instruction["landmarkNodeID"]
      fail_with("#{label} edge #{edge['id']} #{key} references unknown landmark node") if landmark_id && !node_id_set[landmark_id]
    end
  end

  if coverage_mode == "platformCheckpoints"
    fail_with("#{label} checkpoint-only coverage must not contain path edges") unless edges.empty?
  else
    fail_with("#{label} transfer-path coverage requires edges") if edges.empty?
    fail_with("#{label} has a platform unreachable from another platform") unless platforms_all_reachable?(nodes, edges)
  end

  Array(indoor_map["boardingZoneHints"]).each do |hint|
    fail_with("#{label} has an unknown boarding zone") unless BOARDING_ZONES.include?(hint["zone"])
    fail_with("#{label} boarding zone has unknown confidence #{hint['confidence']}") unless DATA_CONFIDENCES.include?(hint["confidence"])
    if indoor_map.dig("provenance", "reviewStatus") != "onSiteVerified" && hint["confidence"] == "official"
      fail_with("#{label} boarding zone cannot claim official confidence without on-site verification")
    end
    fail_with("#{label} boarding zone references unknown evidence node") unless node_id_set[hint["evidenceNodeID"]]
    %w[incomingLineID transferToLineID].each do |key|
      fail_with("#{label} boarding zone #{key} does not serve this station") unless Array(station["lineIDs"]).include?(hint[key])
    end
  end
end

manifest = load_json(MANIFEST_PATH)
station_count = 0

manifest.fetch("cities").each do |city|
  indoor_maps_url = city["indoorMapsDownloadURL"]
  next unless indoor_maps_url

  indoor_maps_path = File.expand_path(indoor_maps_url, DATA_PACKS_DIR)
  fail_with("#{city['cityID']} indoor_maps file is missing") unless File.file?(indoor_maps_path)
  data = File.binread(indoor_maps_path)
  fail_with("#{city['cityID']} indoor_maps size does not match manifest") unless city["indoorMapsSizeBytes"] == data.bytesize
  fail_with("#{city['cityID']} indoor_maps SHA-256 does not match manifest") unless city["indoorMapsSHA256"].to_s.casecmp(Digest::SHA256.hexdigest(data)).zero?

  network_path = File.join(NETWORKS_DIR, "#{city['cityID']}.json")
  fail_with("#{city['cityID']} metro network is missing") unless File.file?(network_path)
  network = load_json(network_path)
  stations_by_name = network.fetch("stations").to_h { |station| [station.fetch("name"), station] }
  lines_by_id = network.fetch("lines").to_h { |line| [line.fetch("id"), line] }
  pack_path = File.expand_path(city.fetch("downloadURL"), DATA_PACKS_DIR)
  pack_dir = File.dirname(pack_path)
  pack = load_json(pack_path)
  pack_stations_by_name = pack.fetch("stations").to_h { |station| [station.fetch("stationName"), station] }

  indoor_pack = JSON.parse(data)
  fail_with("#{city['cityID']} indoor_maps cityID mismatch") unless indoor_pack["cityID"] == city["cityID"]
  fail_with("#{city['cityID']} indoor_maps version mismatch") unless indoor_pack["version"] == city["version"]
  stations = Array(indoor_pack["stations"])
  station_names = stations.map { |station| station["stationName"] }
  fail_with("#{city['cityID']} indoor_maps has duplicate stations") if station_names.uniq.length != station_names.length

  expected_names = network.fetch("stations").each_with_object([]) do |station, names|
    pack_station = pack_stations_by_name[station["name"]]
    if Array(station["lineIDs"]).length > 1 && !Array(pack_station&.fetch("stationMaps", nil)).empty?
      names << station["name"]
    end
  end
  missing = expected_names - station_names
  fail_with("#{city['cityID']} is missing diagram-backed interchanges: #{missing.join(', ')}") unless missing.empty?

  stations.each do |item|
    name = item["stationName"]
    station = stations_by_name[name]
    station_map = Array(pack_stations_by_name.dig(name, "stationMaps")).first
    fail_with("#{city['cityID']} #{name} is absent from the metro network") unless station
    fail_with("#{city['cityID']} #{name} has no station-map source") unless station_map
    validate_indoor_map("#{city['cityID']} #{name}", item.fetch("indoorMap"), station, lines_by_id, station_map, pack_dir)
    station_count += 1
  end
end

puts "indoor-map validation ok: stations=#{station_count}"
