#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"

ROOT = File.expand_path("..", __dir__)
NETWORK_DIR = File.join(ROOT, "JustGo", "Resources", "MetroNetworks")
PACK_PATTERN = File.join(ROOT, "DataPacks", "packs", "*", "*", "city_pack.json")
SEPARATORS = %r{[/／、+＋&＆]}
CHINESE_DIGITS = {
  "零" => 0, "〇" => 0, "一" => 1, "二" => 2, "三" => 3, "四" => 4,
  "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9
}.freeze

def fail_with(message)
  warn "schedule-color validation failed: #{message}"
  exit 1
end

def chinese_number(value)
  total = 0
  digit = 0
  value.each_char do |character|
    if CHINESE_DIGITS.key?(character)
      digit = CHINESE_DIGITS.fetch(character)
    elsif character == "十"
      total += (digit.zero? ? 1 : digit) * 10
      digit = 0
    elsif character == "百"
      total += (digit.zero? ? 1 : digit) * 100
      digit = 0
    else
      return nil
    end
  end
  total + digit
end

def full_line_name(value)
  value.to_s
    .gsub(/\s+/, "")
    .gsub(/地铁|轨道交通/, "")
    .downcase
    .gsub(/[零〇一二三四五六七八九十百]+(?=号线)/) { |text| chinese_number(text).to_s }
end

def simplified_line_name(value)
  full_line_name(value).gsub(/（.*?）|\(.*?\)/, "")
end

def line_references(value)
  normalized = simplified_line_name(value)
  references = Set.new
  references << normalized unless normalized.empty?
  reference = normalized[/[a-z]?\d+(?=号?线|$)/]
  references << reference if reference
  references
end

def normalized_station_name(value)
  value.to_s.gsub(/地铁站|站|\s+/, "").downcase
end

def compact_line_name(value)
  value.gsub(SEPARATORS, "")
end

def line_tokens(value)
  value.split(SEPARATORS).reject(&:empty?).to_set
end

def suffix_safe_contains(longer, shorter)
  return false if longer == shorter || shorter.empty?

  offset = 0
  while (index = longer.index(shorter, offset))
    before = index.zero? ? nil : longer[index - 1]
    after_index = index + shorter.length
    after = after_index >= longer.length ? nil : longer[after_index]
    return true unless before.to_s.match?(/\d/) || after.to_s.match?(/\d/)

    offset = after_index
  end
  false
end

def indexed_line(line)
  names = [line["name"], line["nameEn"]].compact
  {
    line: line,
    full_names: names.map { |name| full_line_name(name) }.reject(&:empty?).to_set,
    simplified_names: names.map { |name| simplified_line_name(name) }.reject(&:empty?).to_set,
    references: names.flat_map { |name| line_references(name).to_a }.to_set.merge(line_references(line["routeReference"])),
    logical_ids: [line["id"], line["logicalLineID"]].compact.map { |id| full_line_name(id) }.to_set
  }
end

def target_for(value)
  full = full_line_name(value)
  simplified = simplified_line_name(value)
  {
    full_names: Set.new([full].reject(&:empty?)),
    simplified_names: Set.new([simplified].reject(&:empty?)),
    references: line_references(value),
    logical_ids: Set.new([full, simplified].reject(&:empty?))
  }
end

def resolve(target, lines, fuzzy:, sole_line:)
  matchers = [
    ->(line) { !(line[:full_names] & target[:full_names]).empty? },
    ->(line) { !(line[:references] & target[:references]).empty? },
    ->(line) { !(line[:logical_ids] & target[:logical_ids]).empty? },
    ->(line) { !(line[:simplified_names] & target[:simplified_names]).empty? }
  ]
  if fuzzy
    matchers << lambda do |line|
      line[:simplified_names].any? do |name|
        target[:simplified_names].any? do |candidate|
          compact_line_name(name) == compact_line_name(candidate) ||
            line_tokens(name) == line_tokens(candidate) ||
            suffix_safe_contains(name, candidate) ||
            suffix_safe_contains(candidate, name)
        end
      end
    end
  end

  matchers.each do |matcher|
    matches = lines.select(&matcher)
    colors = matches.map { |line| line[:line].fetch("colorHex") }.uniq
    return [:resolved, colors.first, matches] if colors.length == 1
    return [:ambiguous, nil, matches] unless matches.empty?
  end
  return [:resolved, lines.first[:line].fetch("colorHex"), lines] if sole_line && lines.length == 1

  [:unmatched, nil, []]
end

Dir.glob(PACK_PATTERN).sort.each do |pack_path|
  pack = JSON.parse(File.read(pack_path))
  city_id = pack.fetch("cityID")
  network_path = File.join(NETWORK_DIR, "#{city_id}.json")
  next unless File.file?(network_path)

  network = JSON.parse(File.read(network_path))
  lines = network.fetch("lines").map { |line| indexed_line(line) }
  lines_by_id = lines.to_h { |line| [line[:line].fetch("id"), line] }
  stations_by_name = network.fetch("stations").group_by { |station| normalized_station_name(station.fetch("name")) }
  counts = Hash.new(0)
  unresolved_names = Hash.new(0)

  pack.fetch("stations").each do |station|
    station_matches = stations_by_name.fetch(normalized_station_name(station.fetch("stationName")), [])
    station_line_ids = station_matches.flat_map { |match| match.fetch("lineIDs") }.uniq.to_set
    station_lines = station_line_ids.map { |line_id| lines_by_id[line_id] }.compact

    Array(station["schedules"]).each do |schedule|
      candidates = station_lines.empty? ? lines : station_lines
      status, _color, matches = resolve(
        target_for(schedule.fetch("lineName")),
        candidates,
        fuzzy: !station_lines.empty?,
        sole_line: !station_lines.empty?
      )
      counts[status] += 1
      unresolved_names[schedule.fetch("lineName")] += 1 unless status == :resolved
      next if station_lines.empty? || status != :resolved

      resolved_ids = matches.map { |match| match[:line].fetch("id") }.to_set
      unless resolved_ids.subset?(station_line_ids)
        fail_with("#{city_id} #{station["stationName"]} #{schedule["lineName"]} resolved outside station membership")
      end
    end
  end

  unresolved = unresolved_names.sort_by { |name, count| [-count, name] }.first(8)
  summary = unresolved.map { |name, count| "#{name}=#{count}" }.join(", ")
  puts "#{city_id}: resolved=#{counts[:resolved]} ambiguous=#{counts[:ambiguous]} unmatched=#{counts[:unmatched]}#{summary.empty? ? "" : " unresolved=[#{summary}]"}"
end

puts "schedule-color validation ok"
