#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates any per-station `indoorMap` blocks embedded in city packs (hand-traced node
# graphs used to draw a real transfer path on the station's official diagram image — see
# JustGo/Models/Transit/IndoorNavigation.swift). Most stations have no `indoorMap` at all;
# this script only checks the ones that do.

require "json"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
MANIFEST_PATH = File.join(DATA_PACKS_DIR, "manifest.json")

NODE_KINDS = %w[platform exit gate elevator escalator stairs corridor concourse].freeze

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
    fail_with("#{label} coordinate.#{axis} must be within 0...1") unless value >= 0.0 && value <= 1.0
  end
end

# Undirected-ish reachability (an edge is only walkable in reverse when isBidirectional):
# every platform node must be able to reach every other platform node, so a typo'd edge
# doesn't silently strand a platform with no route out.
def platforms_all_reachable?(nodes, edges)
  platform_ids = nodes.select { |n| n["kind"] == "platform" }.map { |n| n["id"] }
  return true if platform_ids.length < 2

  adjacency = Hash.new { |h, k| h[k] = [] }
  edges.each do |edge|
    adjacency[edge["fromNodeID"]] << edge["toNodeID"]
    adjacency[edge["toNodeID"]] << edge["fromNodeID"] if edge["isBidirectional"]
  end

  start = platform_ids.first
  visited = { start => true }
  queue = [start]
  until queue.empty?
    current = queue.shift
    adjacency[current].each do |neighbor|
      next if visited[neighbor]

      visited[neighbor] = true
      queue << neighbor
    end
  end

  platform_ids.all? { |id| visited[id] }
end

def validate_indoor_map(label, indoor_map)
  fail_with("#{label} indoorMap.stationID is missing") if indoor_map["stationID"].to_s.empty?

  levels = indoor_map["levels"]
  fail_with("#{label} indoorMap.levels must be a non-empty array") unless levels.is_a?(Array) && !levels.empty?
  level_ids = levels.map { |l| l["id"] }
  fail_with("#{label} indoorMap.levels has duplicate ids") if level_ids.uniq.length != level_ids.length
  ordinals = levels.map { |l| l["ordinal"] }
  fail_with("#{label} indoorMap.levels must be sorted by ordinal") unless ordinals == ordinals.sort

  nodes = indoor_map["nodes"]
  fail_with("#{label} indoorMap.nodes must be a non-empty array") unless nodes.is_a?(Array) && !nodes.empty?
  node_ids = nodes.map { |n| n["id"] }
  fail_with("#{label} indoorMap.nodes has duplicate ids") if node_ids.uniq.length != node_ids.length

  nodes.each do |node|
    fail_with("#{label} node #{node['id']} has unknown kind #{node['kind']}") unless NODE_KINDS.include?(node["kind"])
    fail_with("#{label} node #{node['id']} references unknown levelID #{node['levelID']}") unless level_ids.include?(node["levelID"])
    validate_coordinate("#{label} node #{node['id']}", node["coordinate"])
  end

  edges = indoor_map["edges"]
  fail_with("#{label} indoorMap.edges must be a non-empty array") unless edges.is_a?(Array) && !edges.empty?
  edge_ids = edges.map { |e| e["id"] }
  fail_with("#{label} indoorMap.edges has duplicate ids") if edge_ids.uniq.length != edge_ids.length

  node_id_set = node_ids.each_with_object({}) { |id, h| h[id] = true }
  edges.each do |edge|
    %w[fromNodeID toNodeID].each do |key|
      ref = edge[key]
      fail_with("#{label} edge #{edge['id']} #{key} references unknown node #{ref}") unless node_id_set[ref]
    end
    fail_with("#{label} edge #{edge['id']} distanceMeters must be positive") unless edge["distanceMeters"].is_a?(Numeric) && edge["distanceMeters"] > 0
    fail_with("#{label} edge #{edge['id']} typicalSeconds must be non-negative") unless edge["typicalSeconds"].is_a?(Numeric) && edge["typicalSeconds"] >= 0
  end

  fail_with("#{label} indoorMap has a platform unreachable from another platform") unless platforms_all_reachable?(nodes, edges)
end

manifest = load_json(MANIFEST_PATH)
station_count = 0

manifest["cities"].each do |city|
  city_id = city["cityID"]
  download_url = city["downloadURL"]
  next if download_url.nil?

  pack_path = File.expand_path(download_url, DATA_PACKS_DIR)
  next unless File.file?(pack_path)

  pack = load_json(pack_path)
  Array(pack["stations"]).each do |station|
    indoor_map = station["indoorMap"]
    next if indoor_map.nil?

    validate_indoor_map("#{city_id} #{station['stationName']}", indoor_map)
    station_count += 1
  end
end

puts "indoor-map validation ok: stations=#{station_count}"
