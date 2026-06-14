#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "set"
require "uri"

ROOT = File.expand_path("..", __dir__)
CACHE_DIR = File.join(ROOT, ".cache", "osm-metro")
OUTPUT_DIR = File.join(ROOT, "JustGo", "Resources", "MetroNetworks")
REPORT_DIR = CACHE_DIR
OVERPASS_URLS = [
  URI("https://overpass-api.de/api/interpreter"),
  URI("https://overpass.kumi.systems/api/interpreter")
].freeze
ATTRIBUTION = "© OpenStreetMap contributors"
LICENSE_URL = "https://www.openstreetmap.org/copyright"
SOURCE_URL = "https://www.openstreetmap.org"

CITIES = {
  "1100" => { name: "Beijing", bbox: [39.60, 115.85, 40.30, 116.90] },
  "3100" => { name: "Shanghai", bbox: [30.65, 120.75, 31.90, 122.20] },
  "4401" => { name: "Guangzhou", bbox: [22.55, 112.75, 23.90, 114.20] },
  "4403" => { name: "Shenzhen", bbox: [22.35, 113.65, 22.95, 114.75] },
  "5101" => { name: "Chengdu", bbox: [30.20, 103.55, 31.10, 104.65] },
  "3301" => { name: "Hangzhou", bbox: [29.75, 119.65, 30.85, 120.95] }
}.freeze

EARTH_RADIUS = 6_371_000.0
PI = Math::PI
GCJ_A = 6_378_245.0
GCJ_EE = 0.006693421622965943

def fail_with(message)
  warn "OSM metro import failed: #{message}"
  exit 1
end

def normalized(value)
  value.to_s.downcase.gsub(/\s+/, "").gsub(/[地铁線线號号]/, "")
end

def normalized_station_name(value)
  passenger_name = value.to_s.gsub(
    /\s*[\(（][^()（）]*(?:line|platform|站台|線|线)[^()（）]*[\)）]\s*\z/i,
    ""
  )
  normalized(passenger_name)
end

def normalized_color(value)
  color = value.to_s.strip.upcase
  color = "##{color}" unless color.start_with?("#")
  color.match?(/\A#[0-9A-F]{6}\z/) ? color : "#8E8E93"
end

def source_color(value)
  color = value.to_s.strip.upcase
  color = "##{color}" unless color.start_with?("#")
  color.match?(/\A#[0-9A-F]{6}\z/) ? color : nil
end

def passenger_line_name(tags)
  value = tags["name:zh"] || tags["name"] || tags["ref"] || "Metro"
  value.split(/[:：→]/, 2).first.strip.gsub(/\A地铁\s*/, "")
end

def line_name_tokens(value)
  value.to_s.split(%r{[/／、+＋&＆]}).map { |token| normalized(token) }.reject(&:empty?).uniq.sort
end

def network_identity(tags)
  normalized(tags["network"].to_s.empty? ? tags["operator"] : tags["network"])
end

def inferred_route_reference(tags, name)
  explicit = normalized(tags["ref"])
  return explicit unless explicit.empty?

  name.to_s[/\d+[a-z]?/i].to_s.downcase
end

def service_identity(tags)
  normalized(tags["wikidata"])
end

def ratio(numerator, denominator)
  denominator.zero? ? 0.0 : numerator.to_f / denominator
end

def relation_profile(relation, elements_by_key, ways)
  tags = relation.fetch("tags", {})
  stations = relation_station_names(relation, elements_by_key).to_set
  track_nodes = relation_track_ways(relation, ways).flat_map { |way| way["nodes"] }.to_set
  name = passenger_line_name(tags)
  {
    relation: relation,
    id: relation["id"].to_s,
    name: name,
    name_key: normalized(name),
    name_tokens: line_name_tokens(name),
    network: network_identity(tags),
    ref: normalized(tags["ref"]),
    route_ref: inferred_route_reference(tags, name),
    service_identity: service_identity(tags),
    stations: stations,
    track_nodes: track_nodes,
    color: source_color(tags["colour"] || tags["color"])
  }
end

def network_conflict?(left, right)
  !left[:network].empty? && !right[:network].empty? && left[:network] != right[:network]
end

def network_compatible?(left, right)
  !left[:network].empty? && left[:network] == right[:network]
end

def same_service_evidence(left, right)
  station_overlap = left[:stations] & right[:stations]
  track_overlap = left[:track_nodes] & right[:track_nodes]
  station_containment = [
    ratio(station_overlap.length, left[:stations].length),
    ratio(station_overlap.length, right[:stations].length)
  ].max
  track_containment = [
    ratio(track_overlap.length, left[:track_nodes].length),
    ratio(track_overlap.length, right[:track_nodes].length)
  ].max
  {
    stationContainment: station_containment.round(3),
    sharedStations: station_overlap.length,
    trackContainment: track_containment.round(3),
    sharedTrackNodes: track_overlap.length
  }
end

def structured_service?(left, right)
  return false if network_conflict?(left, right)
  return true if !left[:service_identity].empty? && left[:service_identity] == right[:service_identity]

  network_compatible?(left, right) &&
    !left[:route_ref].empty? &&
    left[:route_ref] == right[:route_ref]
end

def same_named_service?(left, right, evidence)
  return false if left[:name_key].empty? || left[:name_key] != right[:name_key]
  return true if network_compatible?(left, right)
  return false unless left[:network].empty? || right[:network].empty?

  evidence[:stationContainment] >= 0.8 || evidence[:trackContainment] >= 0.5
end

def combined_service?(combined, component, evidence)
  return false if combined[:name_tokens].length < 2
  return false unless combined[:name_tokens].include?(component[:name_key])
  return false unless network_compatible?(combined, component)
  return false if evidence[:sharedStations] < [2, component[:stations].length].min

  evidence[:stationContainment] >= 0.9 || evidence[:trackContainment] >= 0.5
end

def profile_summary(profile)
  {
    "relationID" => profile[:id],
    "name" => profile[:name],
    "networkIdentity" => profile[:network],
    "ref" => profile[:ref],
    "routeReference" => profile[:route_ref],
    "serviceIdentity" => profile[:service_identity]
  }
end

def canonicalize_relations(relations, elements_by_key, ways)
  profiles = relations.map { |relation| relation_profile(relation, elements_by_key, ways) }
  parent = profiles.each_index.to_a
  find = lambda do |index|
    root = index
    root = parent[root] while parent[root] != root
    while parent[index] != index
      next_index = parent[index]
      parent[index] = root
      index = next_index
    end
    root
  end
  union = lambda do |left, right|
    left_root = find.call(left)
    right_root = find.call(right)
    parent[[left_root, right_root].max] = [left_root, right_root].min unless left_root == right_root
  end
  accepted = []
  rejected = []

  profiles.each_index.to_a.combination(2) do |left_index, right_index|
    left = profiles[left_index]
    right = profiles[right_index]
    evidence = same_service_evidence(left, right)
    reason = if structured_service?(left, right)
               "structuredIdentity"
             elsif same_named_service?(left, right, evidence)
               "sameName"
             elsif combined_service?(left, right, evidence) || combined_service?(right, left, evidence)
               "combinedService"
             end
    if reason
      union.call(left_index, right_index)
      accepted << {
        "left" => profile_summary(left),
        "right" => profile_summary(right),
        "reason" => reason,
        "evidence" => evidence
      }
    elsif left[:name_key] == right[:name_key] ||
          left[:name_tokens].include?(right[:name_key]) ||
          right[:name_tokens].include?(left[:name_key])
      different_network = network_conflict?(left, right)
      rejected << {
        "left" => profile_summary(left),
        "right" => profile_summary(right),
        "reason" => different_network ? "differentNetwork" : "insufficientEvidence",
        "ambiguous" => !different_network &&
          evidence[:sharedStations] >= 2 &&
          (evidence[:stationContainment] >= 0.6 || evidence[:trackContainment] >= 0.25),
        "evidence" => evidence
      }
    end
  end

  groups = profiles.each_index.group_by { |index| find.call(index) }.values.map do |indices|
    indices.map { |index| profiles[index] }
  end
  structured_groups = {}
  groups.each_with_index do |group, group_index|
    group.each do |profile|
      next if profile[:network].empty? || profile[:route_ref].empty?
      key = [profile[:network], profile[:route_ref]]
      previous = structured_groups[key]
      fail_with("structured line identity split across groups: #{key.join("/")}") if previous && previous != group_index
      structured_groups[key] = group_index
    end
  end
  ambiguous = rejected.select { |candidate| candidate["ambiguous"] }
  fail_with("ambiguous logical-line candidates: #{ambiguous.map { |candidate| "#{candidate.dig("left", "relationID")}/#{candidate.dig("right", "relationID")}" }.join(", ")}") unless ambiguous.empty?
  [groups, { "acceptedMerges" => accepted, "rejectedCandidates" => rejected }]
end

def canonical_profile(profiles)
  profiles.max_by do |profile|
    [
      profile[:name_tokens].length,
      profile[:stations].length,
      profile[:track_nodes].length,
      profile[:name].length,
      -profile[:id].to_i
    ]
  end
end

def canonical_color(profiles, canonical)
  candidates = profiles.select { |profile| profile[:color] }
  preferred = candidates.select { |profile| profile[:name] == canonical[:name] }
  candidates = preferred unless preferred.empty?
  candidates.max_by do |profile|
    [
      profiles.count { |candidate| candidate[:color] == profile[:color] },
      profile[:stations].length,
      profile[:track_nodes].length,
      -profile[:id].to_i
    ]
  end&.dig(:color) || "#8E8E93"
end

def canonical_route_reference(profiles, canonical)
  return canonical[:route_ref] unless canonical[:route_ref].empty?

  counts = Hash.new(0)
  profiles.each { |profile| counts[profile[:route_ref]] += 1 unless profile[:route_ref].empty? }
  counts.max_by { |reference, count| [count, reference.length, reference] }&.first.to_s
end

def line_id(city_id, key)
  Digest::SHA256.hexdigest("#{city_id}|#{key}")[0, 16]
end

def overpass_query(bbox)
  south, west, north, east = bbox
  <<~QUERY
    [out:json][timeout:180];
    relation["route"="subway"](#{south},#{west},#{north},#{east});
    (._;>>;);
    out body;
  QUERY
end

def fetch_source(city_id, city, refresh:)
  FileUtils.mkdir_p(CACHE_DIR)
  path = File.join(CACHE_DIR, "#{city_id}.json")
  return JSON.parse(File.read(path)) if File.file?(path) && !refresh
  fail_with("#{city[:name]} cache missing; rerun with --refresh") unless refresh

  response = OVERPASS_URLS.lazy.map do |url|
    request = Net::HTTP::Post.new(url)
    request["User-Agent"] = "JustGo metro geometry importer"
    request.set_form_data("data" => overpass_query(city[:bbox]))
    Net::HTTP.start(
      url.host,
      url.port,
      use_ssl: true,
      read_timeout: 240,
      open_timeout: 30
    ) { |http| http.request(request) }
  rescue StandardError => error
    warn "#{city[:name]} Overpass request failed: #{error.message}"
    nil
  end.find { |candidate| candidate.is_a?(Net::HTTPSuccess) }
  fail_with("#{city[:name]} could not fetch a successful Overpass response") unless response
  File.write(path, response.body)
  JSON.parse(response.body)
end

def outside_china?(latitude, longitude)
  longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
end

def transform_latitude(x, y)
  -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(x.abs) +
    (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3 +
    (20 * Math.sin(y * PI) + 40 * Math.sin(y / 3 * PI)) * 2 / 3 +
    (160 * Math.sin(y / 12 * PI) + 320 * Math.sin(y * PI / 30)) * 2 / 3
end

def transform_longitude(x, y)
  300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(x.abs) +
    (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3 +
    (20 * Math.sin(x * PI) + 40 * Math.sin(x / 3 * PI)) * 2 / 3 +
    (150 * Math.sin(x / 12 * PI) + 300 * Math.sin(x / 30 * PI)) * 2 / 3
end

def wgs84_to_gcj02(latitude, longitude)
  return [latitude, longitude] if outside_china?(latitude, longitude)

  delta_latitude = transform_latitude(longitude - 105, latitude - 35)
  delta_longitude = transform_longitude(longitude - 105, latitude - 35)
  radians = latitude / 180 * PI
  magic = 1 - GCJ_EE * Math.sin(radians)**2
  sqrt_magic = Math.sqrt(magic)
  delta_latitude = delta_latitude * 180 / ((GCJ_A * (1 - GCJ_EE)) / (magic * sqrt_magic) * PI)
  delta_longitude = delta_longitude * 180 / (GCJ_A / sqrt_magic * Math.cos(radians) * PI)
  [latitude + delta_latitude, longitude + delta_longitude]
end

def meters_between(a, b)
  latitude = (a[0] + b[0]) / 2 * PI / 180
  x = (b[1] - a[1]) * PI / 180 * Math.cos(latitude)
  y = (b[0] - a[0]) * PI / 180
  Math.sqrt(x * x + y * y) * EARTH_RADIUS
end

def perpendicular_distance(point, start_point, end_point)
  return meters_between(point, start_point) if start_point == end_point

  latitude = (start_point[0] + end_point[0]) / 2 * PI / 180
  scale_x = EARTH_RADIUS * PI / 180 * Math.cos(latitude)
  scale_y = EARTH_RADIUS * PI / 180
  px = (point[1] - start_point[1]) * scale_x
  py = (point[0] - start_point[0]) * scale_y
  ex = (end_point[1] - start_point[1]) * scale_x
  ey = (end_point[0] - start_point[0]) * scale_y
  projection = [[(px * ex + py * ey) / (ex * ex + ey * ey), 0].max, 1].min
  Math.sqrt((px - projection * ex)**2 + (py - projection * ey)**2)
end

def simplify(points, tolerance = 8)
  return points if points.length <= 2

  index, maximum = (1...(points.length - 1)).map { |i| [i, perpendicular_distance(points[i], points.first, points.last)] }
    .max_by(&:last)
  return [points.first, points.last] unless maximum && maximum > tolerance

  simplify(points[0..index], tolerance)[0...-1] + simplify(points[index..], tolerance)
end

def join_way_paths(ways)
  remaining = ways.to_h { |way| [way.fetch("id"), way.fetch("nodes")] }
  paths = []
  until remaining.empty?
    id, nodes = remaining.first
    remaining.delete(id)
    path = nodes.dup
    loop do
      match = remaining.find do |_way_id, candidate|
        [candidate.first, candidate.last].include?(path.first) ||
          [candidate.first, candidate.last].include?(path.last)
      end
      break unless match

      way_id, candidate = match
      remaining.delete(way_id)
      if candidate.first == path.last
        path.concat(candidate.drop(1))
      elsif candidate.last == path.last
        path.concat(candidate.reverse.drop(1))
      elsif candidate.last == path.first
        path = candidate[0...-1] + path
      elsif candidate.first == path.first
        path = candidate.reverse[0...-1] + path
      end
    end
    paths << path if path.length >= 2
  end
  paths
end

def element_coordinate(element, nodes)
  if element["type"] == "node"
    [element["lat"], element["lon"]]
  elsif element["type"] == "way"
    coordinates = Array(element["nodes"]).map { |id| nodes[id] }.compact
    return nil if coordinates.empty?
    [
      coordinates.sum { |coordinate| coordinate[0] } / coordinates.length,
      coordinates.sum { |coordinate| coordinate[1] } / coordinates.length
    ]
  end
end

def named_relation_members(relation, elements_by_key, role_prefix)
  relation.fetch("members", []).map do |member|
    next unless member["role"].to_s.start_with?(role_prefix)
    element = elements_by_key["#{member["type"]}:#{member["ref"]}"]
    name = element&.dig("tags", "name:zh") || element&.dig("tags", "name")
    [member, element, name] unless name.to_s.empty?
  end.compact
end

def passenger_station_members(relation, elements_by_key)
  stops = named_relation_members(relation, elements_by_key, "stop")
  stops.empty? ? named_relation_members(relation, elements_by_key, "platform") : stops
end

def relation_station_names(relation, elements_by_key)
  passenger_station_members(relation, elements_by_key)
    .map { |_member, _element, name| normalized_station_name(name) }
    .uniq
    .sort
end

def ordered_relation_station_names(relation, elements_by_key)
  passenger_station_members(relation, elements_by_key)
    .map { |_member, _element, name| normalized_station_name(name) }
    .reject(&:empty?)
    .chunk_while { |left, right| left == right }
    .map(&:first)
end

def service_pattern_key(relation, elements_by_key)
  names = relation_station_names(relation, elements_by_key)
  names.join("|")
end

def relation_track_ways(relation, ways)
  relation.fetch("members", [])
    .select { |member| member["type"] == "way" && !member["role"].to_s.match?(/platform|stop/) }
    .map { |member| ways[member["ref"]] }.compact
    .uniq { |way| way["id"] }
    .select { |way| Array(way["nodes"]).length >= 2 }
end

def relation_node_set(relation, ways)
  relation_track_ways(relation, ways).flat_map { |way| way["nodes"] }.to_set
end

def physical_station_nodes(elements)
  elements.each_with_object({}) do |element, result|
    next unless element["type"] == "node"
    tags = element.fetch("tags", {})
    name = tags["name:zh"] || tags["name"]
    next if name.to_s.empty?
    next unless tags["railway"] == "stop" || tags["public_transport"] == "stop_position"
    next unless tags["subway"] == "yes" || tags["railway"] == "stop"

    result[element["id"]] = [element, name]
  end
end

def physical_station_patterns(node_paths, station_nodes)
  node_paths.map do |path|
    pattern = path.map { |node_id| station_nodes[node_id]&.last }.compact
      .map { |name| normalized_station_name(name) }
      .reject(&:empty?)
      .chunk_while { |left, right| left == right }
      .map(&:first)
    pattern if pattern.length >= 2
  end.compact
end

def unique_service_patterns(patterns)
  unique = patterns.uniq { |pattern| [pattern, pattern.reverse].min.join("|") }
  unique.reject do |pattern|
    station_set = pattern.to_set
    unique.any? { |candidate| candidate.length > pattern.length && station_set.subset?(candidate.to_set) }
  end
end

def validate_selected_corridors!(relations, elements_by_key, ways)
  relations.combination(2) do |left, right|
    left_stations = relation_station_names(left, elements_by_key).to_set
    right_stations = relation_station_names(right, elements_by_key).to_set
    shared_stations = left_stations & right_stations
    next if shared_stations.length < 3

    station_containment = [
      ratio(shared_stations.length, left_stations.length),
      ratio(shared_stations.length, right_stations.length)
    ].max
    next if station_containment < 0.8

    left_nodes = relation_node_set(left, ways)
    right_nodes = relation_node_set(right, ways)
    shared_nodes = left_nodes & right_nodes
    track_containment = [
      ratio(shared_nodes.length, left_nodes.length),
      ratio(shared_nodes.length, right_nodes.length)
    ].max
    next if track_containment >= 0.25

    fail_with("ambiguous parallel passenger corridors: #{left["id"]}/#{right["id"]}")
  end
end

def passenger_service_patterns(relations, elements_by_key)
  exact_patterns = relations.group_by { |relation| service_pattern_key(relation, elements_by_key) }
  patterns = exact_patterns.map do |key, candidates|
    { key: key, stations: relation_station_names(candidates.first, elements_by_key).to_set, candidates: candidates }
  end
  patterns.sort_by { |pattern| -pattern[:stations].length }.each_with_object([]) do |pattern, merged|
    containing = merged.find { |candidate| pattern[:stations].subset?(candidate[:stations]) }
    if containing
      containing[:candidates].concat(pattern[:candidates])
    else
      merged << pattern
    end
  end
end

def select_service_relations(relations, elements_by_key, ways)
  patterns = passenger_service_patterns(relations, elements_by_key)
  selected_nodes = Set.new
  decisions = []
  selections = patterns.map do |pattern|
    candidates = pattern[:candidates]
    selected = candidates.max_by do |relation|
      track_ways = relation_track_ways(relation, ways)
      nodes = track_ways.flat_map { |way| way["nodes"] }.to_set
      [
        (nodes & selected_nodes).length,
        relation_station_names(relation, elements_by_key).length,
        nodes.length,
        track_ways.length,
        -relation["id"].to_i
      ]
    end
    nodes = relation_node_set(selected, ways)
    decisions << {
      "servicePattern" => pattern[:key],
      "candidateRelationIDs" => candidates.map { |relation| relation["id"].to_s }.sort,
      "selectedRelationID" => selected["id"].to_s,
      "sharedSelectedTrackNodes" => (nodes & selected_nodes).length,
      "uniqueTrackNodes" => (nodes - selected_nodes).length
    }
    selected_nodes.merge(nodes)
    selected
  end
  validate_selected_corridors!(selections, elements_by_key, ways)
  [selections, patterns.length, decisions]
end

def canonical_path_key(path)
  forward = path.join(",")
  reverse = path.reverse.join(",")
  forward < reverse ? forward : reverse
end

def build_network(city_id, city, source)
  elements = source.fetch("elements")
  nodes = elements.select { |item| item["type"] == "node" }.to_h do |node|
    [node["id"], [node["lat"], node["lon"]]]
  end
  elements_by_key = elements.to_h { |item| ["#{item["type"]}:#{item["id"]}", item] }
  ways = elements.select { |item| item["type"] == "way" }.to_h { |way| [way["id"], way] }
  station_nodes = physical_station_nodes(elements)
  relations = elements.select { |item| item["type"] == "relation" && item.dig("tags", "route") == "subway" }
  passenger_relations, evidence_only_relations = relations.partition do |relation|
    passenger_station_members(relation, elements_by_key).any?
  end
  groups, canonicalization_report = canonicalize_relations(passenger_relations, elements_by_key, ways)
  service_pattern_decisions = []

  station_groups = {}
  lines = groups.map do |profiles|
    canonical = canonical_profile(profiles)
    direction_relations = profiles.map { |profile| profile[:relation] }
    canonical_network = canonical[:network].empty? ? "unknown" : canonical[:network]
    route_reference = canonical_route_reference(profiles, canonical)
    key = [canonical_network, route_reference.empty? ? normalized(canonical[:name]) : route_reference].join("|")
    id = line_id(city_id, key)
    selected_relations, service_pattern_count, pattern_decisions =
      select_service_relations(direction_relations, elements_by_key, ways)
    service_pattern_decisions.concat(pattern_decisions.map { |decision| decision.merge("logicalLineID" => id) })
    member_ways = selected_relations.flat_map { |relation| relation_track_ways(relation, ways) }
      .uniq { |way| way["id"] }
    seen_paths = Set.new
    node_paths = join_way_paths(member_ways).select { |path| seen_paths.add?(canonical_path_key(path)) }
    track_station_patterns = physical_station_patterns(node_paths, station_nodes)
    coordinate_paths = node_paths.map do |path|
      coordinates = path.map { |node_id| nodes[node_id] }.compact.map { |coordinate| wgs84_to_gcj02(*coordinate) }
      next if coordinates.length < 2
      simplify(coordinates).map { |latitude, longitude| { "latitude" => latitude.round(6), "longitude" => longitude.round(6) } }
    end.compact
    next if coordinate_paths.empty?

    direction_relations.each do |relation|
      passenger_station_members(relation, elements_by_key).each do |_member, element, name|
        coordinate = element_coordinate(element, nodes) if element
        next if name.to_s.empty? || coordinate.nil?
        station = station_groups[normalized_station_name(name)] ||= {
          "name" => name,
          "nameEn" => element.dig("tags", "name:en"),
          "coordinates" => [],
          "lineIDs" => Set.new
        }
        station["coordinates"] << coordinate
        station["lineIDs"] << id
      end
    end
    member_ways.flat_map { |way| way.fetch("nodes", []) }.uniq.each do |node_id|
      element, name = station_nodes[node_id]
      next unless element && name

      station = station_groups[normalized_station_name(name)] ||= {
        "name" => name,
        "nameEn" => element.dig("tags", "name:en"),
        "coordinates" => [],
        "lineIDs" => Set.new
      }
      station["coordinates"] << [element["lat"], element["lon"]]
      station["lineIDs"] << id
    end

    relation_patterns = selected_relations.map { |relation| ordered_relation_station_names(relation, elements_by_key) }
    service_patterns = unique_service_patterns(track_station_patterns + relation_patterns)

    {
      "id" => id,
      "logicalLineID" => id,
      "networkIdentity" => canonical_network,
      "routeReference" => route_reference,
      "name" => canonical[:name],
      "nameEn" => canonical[:relation].dig("tags", "name:en")&.split(/[:→]/, 2)&.first&.strip,
      "colorHex" => canonical_color(profiles, canonical),
      "stationIDs" => [],
      "servicePatterns" => service_patterns.map do |pattern|
        pattern.map { |name| Digest::SHA256.hexdigest("#{city_id}|#{name}")[0, 16] }
      end,
      "paths" => coordinate_paths,
      "sourceRelationIDs" => direction_relations.map { |relation| relation["id"].to_s }.sort,
      "selectedSourceRelationIDs" => selected_relations.map { |relation| relation["id"].to_s }.sort,
      "servicePatternCount" => service_pattern_count
    }
  end.compact

  stations = station_groups.map do |name_key, station|
    next if station["lineIDs"].empty?
    latitude = station["coordinates"].sum { |coordinate| coordinate[0] } / station["coordinates"].length
    longitude = station["coordinates"].sum { |coordinate| coordinate[1] } / station["coordinates"].length
    latitude, longitude = wgs84_to_gcj02(latitude, longitude)
    {
      "id" => Digest::SHA256.hexdigest("#{city_id}|#{name_key}")[0, 16],
      "name" => station["name"],
      "nameEn" => station["nameEn"],
      "latitude" => latitude.round(6),
      "longitude" => longitude.round(6),
      "lineIDs" => station["lineIDs"].to_a.sort
    }
  end.compact
  station_ids_by_line = Hash.new { |hash, key| hash[key] = [] }
  stations.each { |station| station["lineIDs"].each { |id| station_ids_by_line[id] << station["id"] } }
  lines.each { |line| line["stationIDs"] = station_ids_by_line[line["id"]] }
  empty_lines = lines.select { |line| line["stationIDs"].empty? }
  fail_with("#{city[:name]} emitted lines without passenger stations") unless empty_lines.empty?
  structured_line_keys = lines.map do |line|
    next if line["networkIdentity"] == "unknown" || line["routeReference"].empty?
    [line["networkIdentity"], line["routeReference"]]
  end.compact
  fail_with("#{city[:name]} emitted duplicate structured logical lines") unless structured_line_keys.uniq.length == structured_line_keys.length

  all_coordinates = lines.flat_map { |line| line["paths"].flatten(1) }
  fail_with("#{city[:name]} produced no physical paths") if all_coordinates.empty?
  network = {
    "cityID" => city_id,
    "version" => "osm-#{Date.today.strftime("%Y%m%d")}",
    "bounds" => {
      "minLatitude" => all_coordinates.map { |point| point["latitude"] }.min,
      "minLongitude" => all_coordinates.map { |point| point["longitude"] }.min,
      "maxLatitude" => all_coordinates.map { |point| point["latitude"] }.max,
      "maxLongitude" => all_coordinates.map { |point| point["longitude"] }.max
    },
    "geometrySource" => "openStreetMap",
    "geometryKind" => "physicalTrack",
    "attribution" => ATTRIBUTION,
    "licenseURL" => LICENSE_URL,
    "sourceSnapshot" => Date.today.iso8601,
    "coordinateSystem" => "gcj02",
    "sourceURLs" => [SOURCE_URL, *OVERPASS_URLS.map(&:to_s)],
    "lines" => lines.sort_by { |line| line["name"] },
    "stations" => stations.sort_by { |station| station["name"] }
  }
  report = canonicalization_report.merge(
    "cityID" => city_id,
    "sourceSnapshot" => Date.today.iso8601,
    "canonicalLines" => lines.map do |line|
      {
        "logicalLineID" => line["logicalLineID"],
        "networkIdentity" => line["networkIdentity"],
        "routeReference" => line["routeReference"],
        "name" => line["name"],
        "sourceRelationIDs" => line["sourceRelationIDs"]
      }
    end,
    "suppressedEvidenceOnlyRelations" => evidence_only_relations.map do |relation|
      tags = relation.fetch("tags", {})
      {
        "relationID" => relation["id"].to_s,
        "name" => passenger_line_name(tags),
        "networkIdentity" => network_identity(tags),
        "routeReference" => inferred_route_reference(tags, passenger_line_name(tags)),
        "reason" => "noPassengerStopsOrPlatforms"
      }
    end,
    "servicePatternSelections" => service_pattern_decisions
  )
  [network, report]
end

def self_test
  joined = join_way_paths([
    { "id" => 1, "nodes" => [1, 2, 3] },
    { "id" => 2, "nodes" => [5, 4, 3] },
    { "id" => 3, "nodes" => [8, 9] }
  ])
  fail_with("way endpoint joining test failed") unless joined.any? { |path| path == [1, 2, 3, 4, 5] }
  fail_with("disconnected path test failed") unless joined.any? { |path| path == [8, 9] }
  xidan = wgs84_to_gcj02(39.9057386, 116.3682035)
  fail_with("WGS84 to GCJ-02 test failed") unless meters_between(xidan, [39.9071187, 116.3744198]) < 1
  fixture_elements = {
    "node:10" => { "tags" => { "name" => "A" } },
    "node:11" => { "tags" => { "name" => "B" } },
    "node:12" => { "tags" => { "name" => "C" } },
    "node:13" => { "tags" => { "name" => "D" } },
    "way:20" => { "tags" => { "name" => "A Platform 1" } },
    "way:21" => { "tags" => { "name" => "A Platform 2" } },
    "way:22" => { "tags" => { "name" => "Platform Only A" } },
    "way:23" => { "tags" => { "name" => "Platform Only B" } }
  }
  fixture_ways = {
    100 => { "id" => 100, "nodes" => [1, 2, 3] },
    101 => { "id" => 101, "nodes" => [3, 2, 1] },
    102 => { "id" => 102, "nodes" => [3, 4, 5] },
    103 => { "id" => 103, "nodes" => [6, 7, 8] }
  }
  fixture_relation = lambda do |id, stops, way_ids|
    {
      "id" => id,
      "members" => stops.map { |stop| { "type" => "node", "ref" => stop, "role" => "stop" } } +
        way_ids.map { |way| { "type" => "way", "ref" => way, "role" => "" } }
    }
  end
  selected, patterns = select_service_relations(
    [
      fixture_relation.call(1, [10, 11, 12], [100]),
      fixture_relation.call(2, [12, 11, 10], [101]),
      fixture_relation.call(3, [10, 11, 13], [100, 102]),
      fixture_relation.call(4, [10, 11, 12], [103])
    ],
    fixture_elements,
    fixture_ways
  )
  fail_with("service-pattern selection test failed") unless patterns == 2 && selected.length == 2
  fail_with("parallel direction selection test failed") unless (selected.map { |relation| relation["id"] } & [1, 2, 4]).length == 1
  platform_direction = lambda do |id, platform_id|
    fixture_relation.call(id, [10, 11, 12], [100]).tap do |relation|
      relation["members"] << { "type" => "way", "ref" => platform_id, "role" => "platform" }
    end
  end
  platform_selected, platform_patterns = select_service_relations(
    [platform_direction.call(5, 20), platform_direction.call(6, 21)],
    fixture_elements,
    fixture_ways
  )
  fail_with("platform difference created a service pattern") unless platform_patterns == 1 && platform_selected.length == 1
  subset_patterns = passenger_service_patterns(
    [
      fixture_relation.call(30, [10, 11, 12], [100]),
      fixture_relation.call(31, [10, 12], [100])
    ],
    fixture_elements
  )
  fail_with("express subset created a separate passenger corridor") unless subset_patterns.length == 1
  branch_patterns = passenger_service_patterns(
    [
      fixture_relation.call(32, [10, 11, 12], [100]),
      fixture_relation.call(33, [10, 11, 13], [102])
    ],
    fixture_elements
  )
  fail_with("branch with unique passenger stops was collapsed") unless branch_patterns.length == 2
  platform_only = {
    "id" => 7,
    "members" => [
      { "type" => "way", "ref" => 22, "role" => "platform" },
      { "type" => "way", "ref" => 23, "role" => "platform" },
      { "type" => "way", "ref" => 100, "role" => "" }
    ]
  }
  fail_with("platform-only fallback test failed") unless relation_station_names(platform_only, fixture_elements).length == 2
  fail_with("stop-first station member test failed") unless relation_station_names(platform_direction.call(5, 20), fixture_elements) == %w[a b c]
  fail_with("reversed path key test failed") unless canonical_path_key([1, 2, 3]) == canonical_path_key([3, 2, 1])
  canonical_fixture = lambda do |id, name, network, stops, way_ids, color = nil, reference = nil|
    fixture_relation.call(id, stops, way_ids).merge(
      "tags" => {
        "route" => "subway",
        "name" => name,
        "network" => network,
        "colour" => color,
        "ref" => reference
      }.compact
    )
  end
  canonical_groups, = canonicalize_relations(
    [
      canonical_fixture.call(10, "Airport Line", "Metro A", [10, 11, 12], [100], "#123456"),
      canonical_fixture.call(11, "Airport Line", "Metro A", [12, 11, 10], [101]),
      canonical_fixture.call(12, "Line 4", "Metro A", [10, 11, 12], [100], "#111111"),
      canonical_fixture.call(13, "Branch Line", "Metro A", [12, 13], [102], "#222222"),
      canonical_fixture.call(14, "Line 4/Branch Line", "Metro A", [10, 11, 12, 13], [100, 102], "#111111"),
      canonical_fixture.call(15, "Line 4", "Metro B", [10, 11, 12], [100], "#111111"),
      canonical_fixture.call(16, "Airport Line", "Metro A", [12, 13], [102], "#654321"),
      canonical_fixture.call(17, "Line 9", "Metro A", [12, 13], [102], "#999999"),
      canonical_fixture.call(18, "Line 20 Local", "Metro A", [10, 11, 12], [100], "#333333", "20"),
      canonical_fixture.call(19, "Line 20 Express", "Metro A", [10, 12], [100], "#333333", "20"),
      canonical_fixture.call(20, "Line 20", "Metro B", [10, 11, 12], [100], "#333333", "20")
    ],
    fixture_elements,
    fixture_ways
  )
  canonical_sets = canonical_groups.map { |group| group.map { |profile| profile[:id] }.sort }
  fail_with("same-service branch canonicalization test failed") unless canonical_sets.include?(%w[10 11 16])
  fail_with("combined-service canonicalization test failed") unless canonical_sets.include?(%w[12 13 14])
  fail_with("independent-network canonicalization test failed") unless canonical_sets.include?(%w[15])
  fail_with("genuine-interchange separation test failed") unless canonical_sets.include?(%w[17])
  fail_with("structured local/express canonicalization test failed") unless canonical_sets.include?(%w[18 19])
  fail_with("same-reference independent-network test failed") unless canonical_sets.include?(%w[20])
  evidence_only = fixture_relation.call(21, [], [100]).merge(
    "tags" => { "route" => "subway", "name" => "Line 20 Direction", "network" => "Metro A", "ref" => "20" }
  )
  fail_with("evidence-only relation classification test failed") unless passenger_station_members(evidence_only, fixture_elements).empty?
  track_stations = physical_station_nodes([
    { "type" => "node", "id" => 1, "tags" => { "name" => "A", "railway" => "stop", "subway" => "yes" } },
    { "type" => "node", "id" => 2, "tags" => { "name" => "Reopened", "railway" => "stop", "subway" => "yes" } },
    { "type" => "node", "id" => 3, "tags" => { "name" => "C", "public_transport" => "stop_position", "subway" => "yes" } },
    { "type" => "node", "id" => 4, "tags" => { "name" => "Nearby but not on track", "railway" => "stop", "subway" => "yes" } }
  ])
  inferred_patterns = physical_station_patterns([[1, 2, 3]], track_stations)
  fail_with("physical-track station topology test failed") unless inferred_patterns == [%w[a reopened c]]
  merged_patterns = unique_service_patterns([%w[a c], %w[a reopened c], %w[a branch]])
  fail_with("physical topology did not supersede stale relation stops") unless merged_patterns.include?(%w[a reopened c]) && !merged_patterns.include?(%w[a c])
  fail_with("physical topology collapsed a genuine branch") unless merged_patterns.include?(%w[a branch])
  puts "OSM metro importer self-test ok"
end

refresh = ARGV.delete("--refresh")
if ARGV.delete("--self-test")
  self_test
  exit
end
city_ids = ARGV.empty? ? CITIES.keys : ARGV
unknown = city_ids - CITIES.keys
fail_with("unknown city IDs: #{unknown.join(", ")}") unless unknown.empty?
FileUtils.mkdir_p(OUTPUT_DIR)
FileUtils.mkdir_p(REPORT_DIR)
reports = []
city_ids.each do |city_id|
  city = CITIES.fetch(city_id)
  source = fetch_source(city_id, city, refresh: !!refresh)
  network, report = build_network(city_id, city, source)
  reports << report
  output = File.join(OUTPUT_DIR, "#{city_id}.json")
  File.write(output, "#{JSON.generate(network)}\n")
  points = network["lines"].sum { |line| line["paths"].sum(&:length) }
  puts "#{city[:name]}: lines=#{network["lines"].length} stations=#{network["stations"].length} points=#{points} -> #{output}"
end
report_output = File.join(REPORT_DIR, "canonicalization_report.json")
File.write(report_output, "#{JSON.pretty_generate({ "cities" => reports })}\n")
puts "Canonicalization report -> #{report_output}"
