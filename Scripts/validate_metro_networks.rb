#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"

ROOT = File.expand_path("..", __dir__)
EARTH_RADIUS = 6_371_000.0
paths = Dir.glob(File.join(ROOT, "JustGo", "Resources", "MetroNetworks", "*.json")).sort
abort "metro network validation failed: no assets" if paths.empty?

def point_segment_distance(point, start_point, end_point)
  latitude = (start_point["latitude"] + end_point["latitude"]) / 2 * Math::PI / 180
  scale_x = EARTH_RADIUS * Math::PI / 180 * Math.cos(latitude)
  scale_y = EARTH_RADIUS * Math::PI / 180
  px = (point["longitude"] - start_point["longitude"]) * scale_x
  py = (point["latitude"] - start_point["latitude"]) * scale_y
  ex = (end_point["longitude"] - start_point["longitude"]) * scale_x
  ey = (end_point["latitude"] - start_point["latitude"]) * scale_y
  return Math.sqrt(px * px + py * py) if ex.zero? && ey.zero?
  projection = [[(px * ex + py * ey) / (ex * ex + ey * ey), 0].max, 1].min
  Math.sqrt((px - projection * ex)**2 + (py - projection * ey)**2)
end

def normalized_station_name(name)
  name.to_s
    .unicode_normalize(:nfkc)
    .downcase
    .gsub(/[[:space:]·・]/, "")
    .gsub(/[（(](?:地铁|metro|line|线路|站台|platform)[^）)]*[）)]/i, "")
end

paths.each do |path|
  network = JSON.parse(File.read(path))
  city = network.fetch("cityID")
  abort "#{city}: not physical-track geometry" unless network["geometryKind"] == "physicalTrack"
  abort "#{city}: wrong geometry source" unless network["geometrySource"] == "openStreetMap"
  abort "#{city}: attribution missing" unless network["attribution"].to_s.include?("OpenStreetMap")
  abort "#{city}: license missing" if network["licenseURL"].to_s.empty?
  abort "#{city}: snapshot missing" if network["sourceSnapshot"].to_s.empty?
  abort "#{city}: coordinate system must be gcj02" unless network["coordinateSystem"] == "gcj02"

  stations = network.fetch("stations")
  station_ids = stations.map { |station| station.fetch("id") }.to_set
  station_names = stations.map { |station| normalized_station_name(station.fetch("name")) }
  abort "#{city}: passenger station name missing" if station_names.any?(&:empty?)
  abort "#{city}: duplicate normalized passenger station" unless station_names.uniq.length == station_names.length
  line_ids = network.fetch("lines").map { |line| line.fetch("id") }.to_set
  logical_line_ids = network.fetch("lines").map { |line| line.fetch("logicalLineID") }
  abort "#{city}: duplicate canonical logical-line ID" unless logical_line_ids.uniq.length == logical_line_ids.length
  abort "#{city}: line ID must be its canonical logical-line ID" unless network.fetch("lines").all? { |line| line.fetch("id") == line.fetch("logicalLineID") }
  display_line_keys = network.fetch("lines").map do |line|
    [line.fetch("networkIdentity"), line.fetch("name").downcase.gsub(/\s+/, "")]
  end
  abort "#{city}: duplicate passenger-facing line within one network" unless display_line_keys.uniq.length == display_line_keys.length
  structured_line_keys = network.fetch("lines").map do |line|
    next if line.fetch("networkIdentity") == "unknown" || line.fetch("routeReference").empty?
    [line.fetch("networkIdentity"), line.fetch("routeReference")]
  end.compact
  abort "#{city}: duplicate structured logical-line identity" unless structured_line_keys.uniq.length == structured_line_keys.length
  source_relation_ids = network.fetch("lines").flat_map { |line| line.fetch("sourceRelationIDs") }
  abort "#{city}: raw source relation belongs to multiple logical lines" unless source_relation_ids.uniq.length == source_relation_ids.length
  stations.each do |station|
    abort "#{city}: station has no canonical line membership" if station.fetch("lineIDs").empty?
    abort "#{city}: station references unknown line" unless station.fetch("lineIDs").all? { |id| line_ids.include?(id) }
    abort "#{city}: station has duplicate canonical line membership" unless station.fetch("lineIDs").uniq.length == station.fetch("lineIDs").length
  end
  network.fetch("lines").each do |line|
    abort "#{city}: canonical network identity missing" if line.fetch("networkIdentity").empty?
    abort "#{city}: invalid color" unless line.fetch("colorHex").match?(/\A#[0-9A-F]{6}\z/)
    abort "#{city}: visible line has no passenger stations" if line.fetch("stationIDs").empty?
    abort "#{city}: line references unknown station" unless line.fetch("stationIDs").all? { |id| station_ids.include?(id) }
    patterns = line.fetch("servicePatterns")
    abort "#{city}: line has no routable service pattern" if patterns.empty?
    abort "#{city}: service pattern contains unknown station" unless patterns.flatten.all? { |id| station_ids.include?(id) }
    abort "#{city}: service pattern contains station outside canonical line" unless patterns.flatten.all? { |id| line.fetch("stationIDs").include?(id) }
    abort "#{city}: service pattern contains adjacent duplicate station" if patterns.any? { |pattern| pattern.each_cons(2).any? { |left, right| left == right } }
    abort "#{city}: line has no physical paths" unless line.fetch("paths").any? { |path_points| path_points.length >= 2 }
    relation_ids = line.fetch("selectedSourceRelationIDs")
    abort "#{city}: selected source relation outside canonical line" unless relation_ids.all? { |id| line.fetch("sourceRelationIDs").include?(id) }
    abort "#{city}: selected source relation count does not match service patterns" unless relation_ids.length == line.fetch("servicePatternCount")
    abort "#{city}: duplicate selected source relation" unless relation_ids.uniq.length == relation_ids.length
    path_keys = line.fetch("paths").map do |points|
      forward = points.map { |point| "#{point["latitude"]},#{point["longitude"]}" }.join("|")
      reverse = points.reverse.map { |point| "#{point["latitude"]},#{point["longitude"]}" }.join("|")
      forward < reverse ? forward : reverse
    end
    abort "#{city}: duplicate or reversed physical paths" unless path_keys.uniq.length == path_keys.length
  end

  segments = network.fetch("lines").flat_map do |line|
    line.fetch("paths").flat_map { |points| points.each_cons(2).to_a }
  end
  distances = network.fetch("stations").map do |station|
    segments.map { |start_point, end_point| point_segment_distance(station, start_point, end_point) }.min
  end.sort
  median = distances[distances.length / 2]
  percentile_95 = distances[(distances.length * 0.95).floor.clamp(0, distances.length - 1)]
  abort "#{city}: median station-to-track distance #{median.round}m exceeds 100m" if median > 100
  abort "#{city}: p95 station-to-track distance #{percentile_95.round}m exceeds 300m" if percentile_95 > 300
  puts "#{city}: station-to-track median=#{median.round}m p95=#{percentile_95.round}m"
end

puts "metro network validation ok: assets=#{paths.length}"
