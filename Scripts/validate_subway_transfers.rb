#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

ROOT = File.expand_path("..", __dir__)
SUBWAY_DATA_DIR = File.join(ROOT, "JustGo", "Resources", "SubwayData")

def normalize_line_name(value)
  value.to_s
    .sub(/\(.*/, "")
    .gsub(/（.*?）|\(.*?\)/, "")
    .gsub(/\s+|北京|地铁|轨道交通/, "")
    .downcase
end

def logical_line_identities(data, lines, station)
  Array(station["lineIDs"]).each_with_object([]) do |line_id, identities|
    line = lines[line_id]
    next unless line

    name = normalize_line_name(line["name"])
    name = line_id.downcase if name.empty?
    identities << [data["cityID"].to_s.downcase, name, line["colorHex"].to_s.strip.downcase].join("|")
  end.uniq
end

stale_flags = {}
expectations = {
  "shanghai" => {
    "东川路" => 1,
    "龙溪路" => 1,
    "嘉定新城" => 1,
    "虹桥路" => 3
  },
  "hangzhou" => {
    "潮王路" => 1,
    "武林门" => 2
  }
}

Dir[File.join(SUBWAY_DATA_DIR, "*.json")].sort.each do |path|
  data = JSON.parse(File.read(path))
  next unless data["lines"].is_a?(Array) && data["stations"].is_a?(Array)

  lines = data["lines"].to_h { |line| [line["lineID"], line] }
  stale = data["stations"].count do |station|
    logical_lines = logical_line_identities(data, lines, station)
    station["isTransferStation"] == true && logical_lines.length <= 1
  end
  stale_flags[File.basename(path, ".json")] = stale if stale.positive?

  city_expectations = expectations[File.basename(path, ".json")] || {}
  city_expectations.each do |station_name, expected_count|
    station = data["stations"].find { |candidate| candidate["name"] == station_name }
    abort("subway transfer validation failed: missing #{station_name}") unless station

    logical_count = logical_line_identities(data, lines, station).length
    unless logical_count == expected_count
      abort("subway transfer validation failed: #{station_name} expected #{expected_count} logical lines, got #{logical_count}")
    end
  end
end

puts "subway transfer validation ok: stale bundled flags ignored at runtime=#{stale_flags.values.sum}"
