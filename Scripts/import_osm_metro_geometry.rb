#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "set"
require "uri"
require_relative "lib/gcj02"
require_relative "lib/line_names"

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
URBAN_ROUTE_MODES = %w[subway light_rail monorail tram].freeze
SUPPORTED_ROUTE_MODES = [*URBAN_ROUTE_MODES, "train"].freeze

# Each city's bounding box overlaps neighbouring systems (Shenzhen↔Hong Kong,
# Guangzhou↔Foshan/Dongguan/intercity, Shanghai↔Suzhou, Hangzhou↔Shaoxing …), so a
# cross-border transfer station would otherwise pull a different system's line into the
# wrong city. `networks` is the allowlist of OSM network/operator identities that truly
# belong to the city — every other route relation in the bbox is dropped. `own_unknown_lines`
# whitelists the handful of the city's own lines that carry no network/operator tag in OSM
# (so they would otherwise be indistinguishable from foreign untagged lines).
# The Pearl River Delta intercity railway (城际铁路) is a scheduled, metro-style service riders
# use to move between the delta's cities, and it interchanges with the metro at shared stations.
# It is named here as its own allowlist entry rather than opening `route=train` generally, so
# mainline/high-speed railway inside the same bounding boxes (国铁/高铁) stays out.
GUANGDONG_INTERCITY_NETWORKS = ["珠三角城际", "粤港澳大湾区城际铁路"].freeze

# Sanity bounds on a declared `interchanges` pair, per kind. Far enough to cover the real thing
# — Guangzhou's widest shared concourse is 350m, Beijing's longest street interchange is 太平桥/
# 复兴门 at 625m — and tight enough that a typo naming the wrong station fails the import instead
# of inventing a transfer across the city.
MAX_INTERCHANGE_METERS = {
  "inStation" => 500,
  "outOfStation" => 1_000
}.freeze

# How the fare treats a declared interchange. Only `continuous` — "the two halves bill as one
# trip" — is expressible, and only where it has been checked; anything undeclared says nothing
# rather than guessing. Whether walking between two stations costs a second fare is operator
# policy, and it does not follow from how far apart they are or whether the walk is indoors:
# Beijing bills 广安门内 -> 牛街 as one trip across 496m of street, while Guangzhou's metro and
# intercity halves share a concourse and still need two separate tickets.
INTERCHANGE_FARES = ["continuous"].freeze

# Interchanges whose two halves live in *different* packs.
#
# The Shenzhen/Hong Kong border crossings are the case that forced this: 罗湖 is in Shenzhen's
# network and 羅湖 is in Hong Kong's, 574m apart across an immigration hall, and a rider crossing
# there is making one interchange between two systems the app shipped as unconnected graphs. A
# per-pack `interchanges` list cannot express it, because neither pack contains both stations.
#
# Applied as a post-pass once every network is built, so both endpoints' real coordinates are in
# hand and the link can be written into *both* packs — either one alone is enough for the app to
# find the edge, but a pack that mentions a crossing it does not carry would be a lie about its
# own contents. A partial import that names one side and not the other fails loudly rather than
# writing half of one.
CROSS_NETWORK_INTERCHANGES = [
  { cities: %w[4403 8100], from: "罗湖", to: "羅湖", kind: "outOfStation" },
  { cities: %w[4403 8100], from: "福田口岸", to: "落馬洲", kind: "outOfStation" }
].freeze

CITIES = {
  "1100" => {
    name: "Beijing", bbox: [39.60, 115.85, 40.30, 116.90],
    networks: ["北京地铁", "北京市郊铁路", "北京亦庄公交有轨电车有限责任公司"],
    own_unknown_lines: ["前门大街有轨电车"],
    # Beijing's two street interchanges (出站换乘): the rider leaves the paid area, walks a block
    # and re-enters. Riders make both every day and the app could not plan either, because two
    # named stations with no shared line are two unconnected nodes in the graph.
    # Both are 虚拟换乘: the rider taps out, walks, taps back in, and the two halves bill as one
    # trip. That is a fare rule, not something the geometry implies — an out-of-station walk
    # charges again in plenty of networks — so it is declared per pair and stays unsaid where
    # it is not known.
    interchanges: [
      { from: "广安门内", to: "牛街", kind: "outOfStation", fare: "continuous" },
      { from: "太平桥", to: "复兴门", kind: "outOfStation", fare: "continuous" }
    ]
  },
  "3100" => {
    name: "Shanghai", bbox: [30.65, 120.75, 31.90, 122.20],
    networks: ["上海地铁", "上海浦东机场旅客捷运系统", "松江有轨电车", "上海市域铁路", "上海市域轨道交通"],
    own_unknown_lines: ["磁浮线"]
  },
  "4401" => {
    name: "Guangzhou", bbox: [22.55, 112.75, 23.90, 114.20],
    networks: ["广州地铁", *GUANGDONG_INTERCITY_NETWORKS],
    own_unknown_lines: [],
    # Metro station first, the intercity station it interchanges with second. Two stations, not
    # one station with two names — they were fused into a single node at the mean of both halves,
    # which put the marker in the gap between two platforms and made the city's station count 7
    # short. See `build_interchanges` for why this is a list and not a distance rule.
    #
    # `outOfStation`, all seven: 城际铁路 is a separate railway with its own gates, its own
    # ticketing and its own security screening. Sharing a forecourt with a metro station does not
    # make it one paid area, and calling these `inStation` told riders they could walk through.
    interchanges: [
      { from: "机场北", to: "白云机场北", kind: "outOfStation" },
      { from: "机场南", to: "白云机场南", kind: "outOfStation" },
      { from: "广州白云站", to: "广州白云", kind: "outOfStation" },
      { from: "广州北站", to: "花都", kind: "outOfStation" },
      { from: "大石", to: "大石东", kind: "outOfStation" },
      { from: "东平", to: "顺德北", kind: "outOfStation" },
      { from: "汉溪长隆", to: "广州长隆", kind: "outOfStation" }
    ]
  },
  "4403" => {
    name: "Shenzhen", bbox: [22.35, 113.65, 22.95, 114.75],
    networks: ["深圳地铁", "深圳有轨电车", "坪山云巴"],
    own_unknown_lines: []
  },
  "5101" => {
    name: "Chengdu", bbox: [30.20, 103.55, 31.10, 104.65],
    networks: ["成都地铁", "成都有轨电车"],
    own_unknown_lines: ["天府机场APM"]
  },
  "3301" => {
    name: "Hangzhou", bbox: [29.75, 119.65, 30.85, 120.95],
    networks: ["杭州地铁"],
    own_unknown_lines: []
  },
  "1200" => { name: "Tianjin", bbox: [38.85, 116.80, 39.45, 117.80], networks: ["天津地铁", "天津轨道交通"], own_unknown_lines: [] },
  "5000" => { name: "Chongqing", bbox: [29.30, 106.20, 29.90, 106.90], networks: ["重庆轨道交通", "重庆地铁"], own_unknown_lines: [] },
  "4201" => { name: "Wuhan", bbox: [30.35, 113.95, 30.85, 114.65], networks: ["武汉地铁", "武汉轨道交通"], own_unknown_lines: [] },
  "3201" => { name: "Nanjing", bbox: [31.70, 118.45, 32.30, 119.05], networks: ["南京地铁", "南京轨道交通"], own_unknown_lines: [] },
  "6101" => { name: "Xian", bbox: [34.05, 108.65, 34.55, 109.25], networks: ["西安地铁", "西安轨道交通"], own_unknown_lines: [] },
  "3205" => { name: "Suzhou", bbox: [31.10, 120.35, 31.55, 120.95], networks: ["苏州轨道交通", "苏州地铁"], own_unknown_lines: [] },
  "4101" => { name: "Zhengzhou", bbox: [34.55, 113.30, 34.95, 113.95], networks: ["郑州地铁", "郑州轨道交通"], own_unknown_lines: [] },
  "4301" => { name: "Changsha", bbox: [28.05, 112.75, 28.45, 113.25], networks: ["长沙地铁", "长沙市轨道交通", "长沙轨道交通"], own_unknown_lines: [] },
  "2101" => { name: "Shenyang", bbox: [41.60, 123.15, 42.00, 123.75], networks: ["沈阳地铁", "沈阳轨道交通"], own_unknown_lines: [] },
  "3702" => { name: "Qingdao", bbox: [35.85, 119.95, 36.45, 120.65], networks: ["青岛地铁", "青岛轨道交通"], own_unknown_lines: [] },
  "2102" => { name: "Dalian", bbox: [38.70, 121.25, 39.15, 122.05], networks: ["大连地铁", "大连轨道交通"], own_unknown_lines: [] },
  "3302" => { name: "Ningbo", bbox: [29.65, 121.30, 30.10, 121.85], networks: ["宁波市轨道交通", "宁波轨道交通", "宁波地铁"], own_unknown_lines: [] },
  "3202" => { name: "Wuxi", bbox: [31.35, 120.10, 31.75, 120.60], networks: ["无锡地铁", "无锡轨道交通"], own_unknown_lines: [] },
  "5301" => { name: "Kunming", bbox: [24.70, 102.50, 25.20, 102.95], networks: ["昆明地铁", "昆明轨道交通"], own_unknown_lines: [] },
  "3601" => { name: "Nanchang", bbox: [28.50, 115.65, 28.90, 116.10], networks: ["南昌地铁", "南昌轨道交通"], own_unknown_lines: [] },
  "3501" => { name: "Fuzhou", bbox: [25.85, 119.10, 26.30, 119.55], networks: ["福州地铁", "福州轨道交通"], own_unknown_lines: [] },
  "3502" => { name: "Xiamen", bbox: [24.40, 117.95, 24.80, 118.25], networks: ["厦门地铁", "厦门轨道交通"], allow_unknown: true, own_unknown_lines: [] },
  "3401" => { name: "Hefei", bbox: [31.60, 117.00, 32.05, 117.50], networks: ["合肥轨道交通", "合肥地铁"], own_unknown_lines: [] },
  "1301" => { name: "Shijiazhuang", bbox: [37.85, 114.30, 38.20, 114.75], networks: ["石家庄地铁", "石家庄市轨道交通", "石家庄轨道交通"], own_unknown_lines: [] },
  "5201" => { name: "Guiyang", bbox: [26.40, 106.50, 26.85, 106.95], networks: ["贵阳地铁", "贵阳轨道交通"], allow_unknown: true, own_unknown_lines: [] },
  "2301" => { name: "Harbin", bbox: [45.55, 126.40, 45.95, 126.90], networks: ["哈尔滨地铁", "哈尔滨轨道交通"], allow_unknown: true, own_unknown_lines: [] },
  "2201" => { name: "Changchun", bbox: [43.65, 125.10, 44.00, 125.55], networks: ["长春轨道交通", "长春地铁"], own_unknown_lines: [] },
  "4501" => { name: "Nanning", bbox: [22.65, 108.10, 23.00, 108.55], networks: ["南宁轨道交通", "南宁地铁"], own_unknown_lines: [] },
  "6201" => { name: "Lanzhou", bbox: [35.95, 103.55, 36.20, 104.05], networks: ["兰州轨道交通", "兰州市轨道交通"], allow_unknown: true, own_unknown_lines: [] },
  "6501" => { name: "Urumqi", bbox: [43.65, 87.40, 44.05, 87.80], networks: ["乌鲁木齐轨道交通", "乌鲁木齐地铁"], allow_unknown: true, own_unknown_lines: [] },
  "1501" => { name: "Hohhot", bbox: [40.70, 111.50, 41.00, 112.00], networks: ["呼和浩特地铁", "呼和浩特轨道交通"], own_unknown_lines: [] },
  "1401" => { name: "Taiyuan", bbox: [37.65, 112.40, 38.05, 112.70], networks: ["太原轨道交通", "太原地铁"], own_unknown_lines: [] },
  "4419" => {
    name: "Dongguan", bbox: [22.85, 113.55, 23.15, 114.00],
    networks: ["东莞轨道交通", "东莞地铁", *GUANGDONG_INTERCITY_NETWORKS],
    own_unknown_lines: []
  },
  "4406" => {
    name: "Foshan", bbox: [22.80, 112.90, 23.25, 113.35],
    networks: ["佛山地铁", "佛山市轨道交通", "佛山有轨电车", *GUANGDONG_INTERCITY_NETWORKS],
    own_unknown_lines: []
  },
  "3303" => { name: "Wenzhou", bbox: [27.75, 120.50, 28.15, 120.95], networks: ["温州轨道交通", "温州市域铁路"], own_unknown_lines: [] },
  "3306" => { name: "Shaoxing", bbox: [29.85, 120.40, 30.15, 120.80], networks: ["绍兴轨道交通"], own_unknown_lines: [] },
  "3203" => { name: "Xuzhou", bbox: [34.10, 117.05, 34.40, 117.45], networks: ["徐州地铁", "徐州轨道交通"], own_unknown_lines: [] },
  "3204" => { name: "Changzhou", bbox: [31.65, 119.80, 31.95, 120.15], networks: ["常州地铁", "常州轨道交通"], own_unknown_lines: [] },
  "3701" => { name: "Jinan", bbox: [36.45, 116.75, 36.80, 117.30], networks: ["济南地铁", "济南轨道交通"], own_unknown_lines: [] },
  "4103" => { name: "Luoyang", bbox: [34.50, 112.30, 34.78, 112.65], networks: ["洛阳地铁", "洛阳轨道交通"], own_unknown_lines: [] },
  "3402" => { name: "Wuhu", bbox: [31.20, 118.25, 31.45, 118.55], networks: ["芜湖轨道交通", "芜湖地铁"], allow_unknown: true, own_unknown_lines: [] },
  "3206" => { name: "Nantong", bbox: [31.85, 120.70, 32.15, 121.05], networks: ["南通地铁", "南通轨道交通"], own_unknown_lines: [] },
  "3310" => { name: "Taizhou", bbox: [28.50, 121.20, 28.80, 121.55], networks: ["台州市域铁路", "台州轨道交通"], own_unknown_lines: [] },
  "8100" => { name: "HongKong", bbox: [22.15, 113.83, 22.58, 114.45], networks: ["港鐵 MTR", "輕鐵 Light Rail", "港铁"], own_unknown_lines: [] },
  "8200" => { name: "Macau", bbox: [22.10, 113.52, 22.22, 113.62], networks: ["澳門輕軌 Metro Ligeiro de Macau", "澳門輕軌", "澳门轻轨", "Macau LRT"], own_unknown_lines: [] },
  # Taipei's three busiest lines (板南, 文湖, 淡水信義) carry no network/operator tag in OSM and
  # exist *only* as untagged relations — without naming them here the city would import with its
  # core network missing. They are listed rather than `allow_unknown` because the same bbox also
  # holds the untagged 貓空纜車 gondola, which is not rail. 新北捷運/淡海輕軌 are the New Taipei
  # half of the same metro system; 桃園捷運 is excluded here and imported as Taoyuan (7106).
  "7101" => {
    name: "Taipei", bbox: [24.90, 121.30, 25.30, 121.80],
    networks: ["臺北捷運", "台北捷運", "新北捷運", "淡海輕軌"],
    own_unknown_lines: [
      "臺北捷運 南港-板橋-土城線",
      "捷運文湖線",
      "淡水信義線",
      "臺北捷運 淡水線-信義線"
    ]
  },
  "7102" => { name: "Kaohsiung", bbox: [22.45, 120.15, 22.85, 120.50], networks: ["高雄捷運", "環狀輕軌"], own_unknown_lines: [] },
  "7104" => { name: "Taichung", bbox: [24.05, 120.55, 24.35, 120.80], networks: ["臺中捷運", "台中捷運"], own_unknown_lines: [] },
  # The bbox reaches Taipei Main Station because the Airport MRT terminates there; the
  # allowlist keeps Taipei's own lines out.
  "7106" => { name: "Taoyuan", bbox: [24.90, 121.15, 25.12, 121.55], networks: ["桃園捷運"], own_unknown_lines: [] },
  # The only route relations in this bbox are the city's own 金义东线, so untagged ones are safe.
  "3307" => { name: "Jinhua", bbox: [28.85, 119.50, 29.45, 120.45], networks: ["浙中都市圈城际轨道交通", "金华轨道交通"], allow_unknown: true, own_unknown_lines: [] },
  # 宁滁线 is Chuzhou-operated and tagged as such; the rest of this bbox is Nanjing Metro, so
  # untagged relations are *not* allowed through here.
  "3411" => { name: "Chuzhou", bbox: [31.95, 118.15, 32.45, 118.70], networks: ["滁州轨道交通"], own_unknown_lines: [] },
  # 郑许线 carries no network tag and is the only rail in the bbox.
  "4110" => { name: "Xuchang", bbox: [33.95, 113.60, 34.45, 114.05], networks: ["许昌轨道交通", "郑许线"], allow_unknown: true, own_unknown_lines: [] }
}.freeze

EARTH_RADIUS = 6_371_000.0
PI = Math::PI

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
  reference = tags["ref"].to_s.strip
  value = LineNames.clean(tags["name:zh"]) || LineNames.clean(tags["name"])
  # Guiyang's relations name the run ("1 窦官 - 小孟工业园") and carry the line only as `ref`, so
  # the reduction leaves a bare number. Every other mainland city in the catalog displays
  # "<n>号线"; rendering it here keeps the map legend consistent instead of showing a lone digit.
  return "#{reference}号线" if !reference.empty? && value == reference && reference.match?(/\A\d+\z/)

  value || (reference.empty? ? "Metro" : reference)
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

  # A line reference is a designation plus a number ("S3", "T1"), not the first digits in the
  # string. This value keys `structured_service?`, so losing the designation does not merely
  # mislabel a line — it fuses two of them: 成都市域铁路S3资阳线 carries no `ref` tag, reduced to
  # "3", matched 成都地铁3号线's ref, and unioned into it, dragging 资阳's stations 60km onto
  # Line 3. Prefer a letter-prefixed form; fall back to bare digits so "Metro Line 10" and
  # "Light Rail 614P" (no letter against the number) keep reading as before.
  (name.to_s[/(?<![a-z])[a-z]{1,2}\d+[a-z]?/i] || name.to_s[/\d+[a-z]?/i]).to_s.downcase
end

def service_identity(tags)
  normalized(tags["wikidata"])
end

# Whether a canonicalized line belongs to the city being imported. `network_identity` is the
# already-normalized network/operator of the line (or "unknown" when OSM gives neither), so it
# is matched against the city's normalized allowlist. Lines with no network/operator are kept
# only if explicitly whitelisted by name (the city's own untagged lines); anything else —
# a neighbouring city's metro, an intercity service, Hong Kong MTR, etc. — is rejected.
def city_owns_line?(city, network_identity, name, mode: nil)
  allowed = (city[:networks] || []).map { |value| normalized(value) }
  return true if allowed.include?(network_identity)
  if network_identity == "unknown"
    # Isolated systems whose OSM relations carry no network/operator tag: there is no
    # neighbouring metro inside the bbox to confuse them with, so keep their untagged lines.
    # `allow_unknown` covers urban modes only. Unidentified heavy rail inside a city bbox is
    # national or cross-border rail, not that city's metro — Urumqi's bbox holds the
    # "13/14 乌鲁木齐<=>Алматы" sleeper to Almaty, tagged route=train network=unknown.
    return true if city[:allow_unknown] && mode != "train"
    return (city[:own_unknown_lines] || []).include?(name)
  end

  false
end

def relation_owned_by_city?(city, relation)
  tags = relation.fetch("tags", {})
  identity = network_identity(tags)
  city_owns_line?(city, identity.empty? ? "unknown" : identity, passenger_line_name(tags), mode: tags["route"])
end

def supported_route_relation?(relation)
  tags = relation.fetch("tags", {})
  mode = tags["route"]
  return true if URBAN_ROUTE_MODES.include?(mode)

  mode == "train" && (
    !network_identity(tags).empty? ||
    %w[urban suburban].include?(tags["passenger"]) ||
    (!normalized(tags["operator"]).empty? && !service_identity(tags).empty?)
  )
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

# The express service on a line the local service also runs: 广惠城际快车 is 广惠城际 skipping
# stops, not a second railway. OSM publishes them as separate relations, so the intercity corridors
# imported as two lines each — and a station on both then claimed two interchanges where a rider
# sees one line with two kinds of train.
#
# `servicePatterns` is exactly the field for this, and until now it went unused for the case it
# was built for. The suffix is the whole rule: 快车/大站快车 appended to a name the city already
# has. Not inferred from station containment, which would also fuse 广清城际 into 广惠城际 (they
# share the whole Guangzhou trunk); the express variant has to *say* it is one.
def express_variant_service?(left, right, evidence)
  base, express = if express_of(right[:name_key]) == left[:name_key]
                    [left, right]
                  elsif express_of(left[:name_key]) == right[:name_key]
                    [right, left]
                  end
  return false if base.nil?
  return false unless network_compatible?(base, express)

  # An express calls at a subset of the local's stops, so it is the express that must be contained.
  evidence[:sharedStations] >= 2 && evidence[:trackContainment] >= 0.5
end

def express_of(name_key)
  stripped = name_key.sub(/大?站?快车\z/, "")
  stripped == name_key ? nil : stripped
end

def combined_service?(combined, component, evidence)
  return false if combined[:name_tokens].length < 2
  return false unless combined[:name_tokens].include?(component[:name_key])
  return false unless network_compatible?(combined, component)
  return false if evidence[:sharedStations] < [2, component[:stations].length].min

  evidence[:stationContainment] >= 0.9 || evidence[:trackContainment] >= 0.5
end

# A through-running service split into two logical lines with no shared name at all (e.g.
# Shenzhen 2号线/8号线): neither `same_named_service?` nor `combined_service?` can fire because
# there is no textual overlap to key on. The identical station set plus identical published
# line colour is what a rider actually uses to recognise "this is one line" — and unlike name
# matching, an exact station-set match is definitionally the same physical corridor, so this
# rule is safe to apply generally rather than special-casing any one city.
def same_corridor_service?(left, right)
  return false if left[:stations].empty? || left[:stations] != right[:stations]
  return false if left[:color].nil? || left[:color] != right[:color]

  network_compatible?(left, right)
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
  same_corridor_indices = Set.new

  profiles.each_index.to_a.combination(2) do |left_index, right_index|
    left = profiles[left_index]
    right = profiles[right_index]
    evidence = same_service_evidence(left, right)
    reason = if structured_service?(left, right)
               "structuredIdentity"
             elsif same_named_service?(left, right, evidence)
               "sameName"
             elsif express_variant_service?(left, right, evidence)
               "expressVariant"
             elsif combined_service?(left, right, evidence) || combined_service?(right, left, evidence)
               "combinedService"
             elsif same_corridor_service?(left, right)
               "sameCorridor"
             end
    if reason
      union.call(left_index, right_index)
      same_corridor_indices.merge([left_index, right_index]) if reason == "sameCorridor"
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

  index_groups = profiles.each_index.group_by { |index| find.call(index) }.values
  groups = index_groups.map { |indices| indices.map { |index| profiles[index] } }
  # Whether this group's *only* connection to a same-name-covering profile is the sameCorridor
  # rule — used to gate `display_line_name` synthesis so an ordinary two-direction line (whose
  # direction relations already merge via `structuredIdentity`/`sameName` and happen to share a
  # station set too) keeps its single representative name instead of getting every direction's
  # raw OSM name concatenated together.
  same_corridor_groups = index_groups.map { |indices| indices.any? { |index| same_corridor_indices.include?(index) } }
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
  [groups, same_corridor_groups, { "acceptedMerges" => accepted, "rejectedCandidates" => rejected }]
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

# Existing merges (`sameName`, `structuredIdentity`, `combinedService`) always leave a single
# profile whose own name already covers every merged profile — either they all share one name,
# or (for `combinedService`) one relation is tagged with the slash-joined name already, and
# `canonical_profile` prefers it for having the most name tokens. `sameCorridor` is the one
# merge kind where no profile's name covers the others (Shenzhen's 2号线 and 8号线 relations
# each carry only their own single-token name), so the display name has to be synthesised.
def display_line_name(profiles, canonical, same_corridor)
  return canonical[:name] if canonical[:name_tokens].length > 1
  # Only synthesise a combined name for a group that merged *because of* the sameCorridor rule
  # (two logical lines with no textual overlap, unioned solely on identical stations + colour,
  # e.g. Shenzhen 2号线/8号线). An ordinary two-direction line's relations already merge via
  # `structuredIdentity`/`sameName` and also happen to share a station set — synthesising there
  # would concatenate every direction's raw OSM name (seen on Taiyuan/Changzhou/Hefei/Luoyang
  # etc., whose direction relations are tagged with distinct from/to-suffixed names).
  return canonical[:name] unless same_corridor

  by_key = profiles.each_with_object({}) { |profile, names| names[profile[:name_key]] ||= profile[:name] }
  return canonical[:name] if by_key.length <= 1

  by_key.values.sort_by { |name| [name.length, name] }.join("/")
end

def line_id(city_id, key)
  Digest::SHA256.hexdigest("#{city_id}|#{key}")[0, 16]
end

# A station's ID is the hash of its *normalized* name, which is also how service patterns
# reference it. Both were computed inline; sharing one definition is what lets the interchange
# merge below rewrite a station ID and its pattern references without them drifting apart.
def station_id(city_id, name_key)
  Digest::SHA256.hexdigest("#{city_id}|#{name_key}")[0, 16]
end

def overpass_query(bbox)
  south, west, north, east = bbox
  <<~QUERY
    [out:json][timeout:180];
    (
      relation["route"~"^(subway|light_rail|monorail|tram)$"](#{south},#{west},#{north},#{east});
      relation["route"="train"]["network"](#{south},#{west},#{north},#{east});
      relation["route"="train"]["passenger"~"^(urban|suburban)$"](#{south},#{west},#{north},#{east});
      relation["route"="train"]["operator"]["wikidata"](#{south},#{west},#{north},#{east});
    );
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
    request["User-Agent"] = "Just-Go metro geometry importer"
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

def wgs84_to_gcj02(latitude, longitude)
  GCJ02.from_wgs84(latitude, longitude)
end

def average_coordinate(station)
  coordinates = station["coordinates"]
  [
    coordinates.sum { |coordinate| coordinate[0] } / coordinates.length,
    coordinates.sum { |coordinate| coordinate[1] } / coordinates.length
  ]
end

# Two named stations riders treat as one interchange.
#
# Two cases, one mechanism, differing only in `kind`, which describes the *walk* and nothing else.
# `inStation` means the two are connected inside the building, as at Guangzhou's metro/intercity
# concourses; `outOfStation` means the rider goes out to the street, as at Beijing's 广安门内/牛街.
# The app draws the first solid and the second dashed. What the fare does is a separate, declared
# fact — see `INTERCHANGE_FARES`.
#
# Declared per pair rather than inferred from distance, because distance cannot separate an
# interchange from two nearby stations that are not one. Measured over Guangzhou's 414 stations,
# the real concourse pairs run out to 350m (汉溪长隆/广州长隆) while 体育西路 and 天河南 — different
# stations, no interchange — are 281m apart. In Beijing 南礼士路 and 复兴门 are 372m apart and are
# *not* an interchange, while 太平桥 and 复兴门 at 625m are. No threshold separates those, so a
# threshold would invent transfers between the busiest stations in both cities. A wrong transfer
# is worse than a missing one.
#
# These used to be merges: the two nodes were fused into one at the mean of their coordinates.
# That put the marker in the gap between two platforms, undercounted the city's stations by one
# per pair, and could only ever express the in-station case.
def build_interchanges(city, city_id, station_groups)
  (city[:interchanges] || []).map do |link|
    from_key = normalized_station_name(link.fetch(:from))
    to_key = normalized_station_name(link.fetch(:to))
    from = station_groups[from_key]
    to = station_groups[to_key]
    # Loud, not skipped: a typo or a renamed station would otherwise silently drop the link and
    # the interchange would quietly stop being plannable again.
    fail_with("#{city[:name]} interchange names an absent station: #{link[:from]}") if from.nil?
    fail_with("#{city[:name]} interchange names an absent station: #{link[:to]}") if to.nil?
    unless (from["lineIDs"] & to["lineIDs"]).empty?
      fail_with("#{city[:name]} interchange #{link[:from]}/#{link[:to]} already share a line")
    end
    limit = MAX_INTERCHANGE_METERS[link.fetch(:kind)]
    fail_with("#{city[:name]} interchange #{link[:from]}/#{link[:to]} has unknown kind #{link[:kind]}") if limit.nil?
    separation = meters_between(average_coordinate(from), average_coordinate(to))
    if separation > limit
      fail_with("#{city[:name]} interchange #{link[:from]}/#{link[:to]} is #{separation.round}m apart")
    end
    fare = link[:fare]
    if fare && !INTERCHANGE_FARES.include?(fare)
      fail_with("#{city[:name]} interchange #{link[:from]}/#{link[:to]} has unknown fare #{fare}")
    end
    record = {
      "fromStationID" => station_id(city_id, from_key),
      "toStationID" => station_id(city_id, to_key),
      "kind" => link.fetch(:kind),
      "walkingDistanceMeters" => separation.round
    }
    record["fare"] = fare if fare
    record
  end.sort_by { |link| [link["fromStationID"], link["toStationID"]] }
end

# Writes each declared cross-pack interchange into both of its networks, now that every station's
# final coordinate exists. See CROSS_NETWORK_INTERCHANGES.
def apply_cross_network_interchanges!(networks_by_city, built_city_ids)
  CROSS_NETWORK_INTERCHANGES.each do |link|
    from_city, to_city = link.fetch(:cities)
    touched = link[:cities] & built_city_ids
    next if touched.empty?
    unless (link[:cities] - built_city_ids).empty?
      fail_with(
        "cross-network interchange #{link[:from]}/#{link[:to]} needs both #{from_city} and " \
        "#{to_city} in the same run"
      )
    end
    from_network = networks_by_city.fetch(from_city)
    to_network = networks_by_city.fetch(to_city)
    from = from_network["stations"].find { |station| station["name"] == link.fetch(:from) }
    to = to_network["stations"].find { |station| station["name"] == link.fetch(:to) }
    fail_with("cross-network interchange names an absent station: #{link[:from]}") if from.nil?
    fail_with("cross-network interchange names an absent station: #{link[:to]}") if to.nil?
    separation = meters_between(
      [from["latitude"], from["longitude"]],
      [to["latitude"], to["longitude"]]
    )
    limit = MAX_INTERCHANGE_METERS.fetch(link.fetch(:kind))
    if separation > limit
      fail_with("cross-network interchange #{link[:from]}/#{link[:to]} is #{separation.round}m apart")
    end
    record = {
      "fromStationID" => from["id"],
      "toStationID" => to["id"],
      "kind" => link.fetch(:kind),
      "walkingDistanceMeters" => separation.round
    }
    record["fare"] = link[:fare] if link[:fare]
    [from_network, to_network].uniq.each do |network|
      network["interchanges"] = (network["interchanges"] + [record])
        .uniq
        .sort_by { |entry| [entry["fromStationID"], entry["toStationID"]] }
    end
  end
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

def passenger_station_members(relation, elements_by_key, include_unbuilt: false)
  stops = named_relation_members(relation, elements_by_key, "stop")
  usable_stops = stops.reject { |_member, _element, name| unbuilt_station_name?(name) }
  if include_unbuilt
    return stops unless usable_stops.empty?
  else
    return usable_stops unless usable_stops.empty?
  end

  platforms = named_relation_members(relation, elements_by_key, "platform")
  include_unbuilt ? platforms : platforms.reject { |_member, _element, name| unbuilt_station_name?(name) }
end

def relation_station_names(relation, elements_by_key)
  passenger_station_members(relation, elements_by_key)
    .map { |_member, _element, name| normalized_station_name(name) }
    .uniq
    .sort
end

def ordered_relation_station_patterns(relation, elements_by_key)
  patterns = []
  current = []
  passenger_station_members(relation, elements_by_key, include_unbuilt: true)
    .each do |_member, _element, name|
      if unbuilt_station_name?(name)
        patterns << current if current.length >= 2
        current = []
        next
      end
      normalized_name = normalized_station_name(name)
      next if normalized_name.empty? || current.last == normalized_name
      current << normalized_name
    end
  patterns << current if current.length >= 2
  patterns
end

def service_pattern_key(relation, elements_by_key)
  names = relation_station_names(relation, elements_by_key)
  names.join("|")
end

def service_terminal_key(relation)
  tags = relation.fetch("tags", {})
  terminals = [normalized_station_name(tags["from"]), normalized_station_name(tags["to"])].reject(&:empty?).sort
  terminals.length == 2 ? terminals.join("|") : nil
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

# Markers OSM mappers append in parentheses for stations that are not yet open
# (under construction / planned / postponed). These stations must not enter the
# bundled network — the app must only surface stations a rider can actually use.
UNBUILT_STATION_MARKERS = %w[在建 规划 筹建 未开通 暂缓 停建].freeze

def unbuilt_station_name?(name)
  name.to_s.scan(/（([^）]*)）|\(([^)]*)\)/).flatten.compact.any? do |content|
    UNBUILT_STATION_MARKERS.any? { |marker| content.include?(marker) }
  end
end

def physical_station_nodes(elements, include_unbuilt: false)
  elements.each_with_object({}) do |element, result|
    next unless element["type"] == "node"
    tags = element.fetch("tags", {})
    name = tags["name:zh"] || tags["name"]
    next if name.to_s.empty?
    next if !include_unbuilt && unbuilt_station_name?(name)
    next unless tags["railway"] == "stop" || tags["public_transport"] == "stop_position"
    next unless tags["subway"] == "yes" || tags["railway"] == "stop"

    result[element["id"]] = [element, name]
  end
end

def physical_station_patterns(node_paths, station_nodes)
  node_paths.flat_map do |path|
    patterns = []
    current = []
    path.each do |node_id|
      name = station_nodes[node_id]&.last
      next unless name
      if unbuilt_station_name?(name)
        patterns << current if current.length >= 2
        current = []
        next
      end
      normalized_name = normalized_station_name(name)
      next if normalized_name.empty? || current.last == normalized_name
      current << normalized_name
    end
    patterns << current if current.length >= 2
    patterns
  end
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
    {
      key: key,
      stations: relation_station_names(candidates.first, elements_by_key).to_set,
      terminal_keys: candidates.map { |relation| service_terminal_key(relation) }.compact.to_set,
      candidates: candidates
    }
  end
  patterns.sort_by { |pattern| -pattern[:stations].length }.each_with_object([]) do |pattern, merged|
    containing = merged.find do |candidate|
      shared_stations = pattern[:stations] & candidate[:stations]
      same_terminals = !(pattern[:terminal_keys] & candidate[:terminal_keys]).empty?
      station_containment = [
        ratio(shared_stations.length, pattern[:stations].length),
        ratio(shared_stations.length, candidate[:stations].length)
      ].max
      pattern[:stations].subset?(candidate[:stations]) || (same_terminals && station_containment >= 0.8)
    end
    if containing
      containing[:candidates].concat(pattern[:candidates])
      containing[:terminal_keys].merge(pattern[:terminal_keys])
    else
      merged << pattern
    end
  end
end

def select_service_relations(relations, elements_by_key, ways)
  patterns = passenger_service_patterns(relations, elements_by_key)
  selected_nodes = Set.new
  decisions = []
  extra_geometry_ways = []
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

    # Rendering-only recovery: every candidate in this group that is not the selected one
    # contributes its track back to the drawn path, never to the routing graph.
    #
    # A real line is two physical tracks, and OSM models each direction as its own relation.
    # Keeping only the selected direction drew a single-track line down a double-track corridor,
    # which is what riders see on the ground and on operator maps. Both directions are therefore
    # unioned in — the plain reverse-direction duplicate (same stops, parallel track) as well as
    # the divergent case folded in by `passenger_service_patterns`'s subset/terminal merge, where
    # a direction skips or adds a stop and its track physically separates (an airport line's
    # one-way loop through a second terminal). `geometry_ways` dedupes by way ID, so a corridor
    # whose directions genuinely share one way is still drawn once.
    candidates.each do |candidate|
      next if candidate.equal?(selected)

      extra_geometry_ways.concat(relation_track_ways(candidate, ways))
    end
    selected
  end
  validate_selected_corridors!(selections, elements_by_key, ways)
  [selections, patterns.length, decisions, extra_geometry_ways.uniq { |way| way["id"] }.sort_by { |way| way["id"] }]
end

def canonical_path_key(path)
  forward = path.join(",")
  reverse = path.reverse.join(",")
  forward < reverse ? forward : reverse
end

# The OSM base timestamp of the Overpass response the city was built from. Cities are refreshed
# individually, so their snapshots genuinely differ (Beijing's cache predates Taipei's by five
# weeks); stamping `Date.today` instead would have every file claim a provenance date it does not
# have. Overpass always returns this, so a response without it is a truncated read, not an old one.
def source_snapshot(city, source)
  timestamp = source.dig("osm3s", "timestamp_osm_base").to_s
  fail_with("#{city[:name]} source has no osm3s.timestamp_osm_base; refetch it") unless
    timestamp =~ /\A(\d{4})-(\d{2})-(\d{2})T/
  "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}-#{Regexp.last_match(3)}"
end

def build_network(city_id, city, source)
  snapshot = source_snapshot(city, source)
  elements = source.fetch("elements")
  nodes = elements.select { |item| item["type"] == "node" }.to_h do |node|
    [node["id"], [node["lat"], node["lon"]]]
  end
  elements_by_key = elements.to_h { |item| ["#{item["type"]}:#{item["id"]}", item] }
  ways = elements.select { |item| item["type"] == "way" }.to_h { |way| [way["id"], way] }
  station_nodes = physical_station_nodes(elements)
  pattern_station_nodes = physical_station_nodes(elements, include_unbuilt: true)
  relations = elements.select { |item| item["type"] == "relation" && supported_route_relation?(item) }
  passenger_relations, evidence_only_relations = relations.partition do |relation|
    passenger_station_members(relation, elements_by_key).any?
  end
  groups, same_corridor_groups, canonicalization_report = canonicalize_relations(passenger_relations, elements_by_key, ways)
  service_pattern_decisions = []

  station_groups = {}
  lines = groups.zip(same_corridor_groups).map do |profiles, same_corridor|
    canonical = canonical_profile(profiles)
    direction_relations = profiles.map { |profile| profile[:relation] }
    canonical_network = canonical[:network].empty? ? "unknown" : canonical[:network]
    # Drop lines that belong to another city's system (pulled in via the bbox / a cross-border
    # transfer station). Skipping the group here means its line and its not-shared stations are
    # never emitted, and a shared transfer station keeps only this city's line IDs.
    next unless city_owns_line?(
      city,
      canonical_network,
      canonical[:name],
      mode: canonical[:relation].dig("tags", "route")
    )
    route_reference = canonical_route_reference(profiles, canonical)
    key = [canonical_network, route_reference.empty? ? normalized(canonical[:name]) : route_reference].join("|")
    id = line_id(city_id, key)
    selected_relations, service_pattern_count, pattern_decisions, extra_geometry_ways =
      select_service_relations(direction_relations, elements_by_key, ways)
    service_pattern_decisions.concat(pattern_decisions.map { |decision| decision.merge("logicalLineID" => id) })
    member_ways = selected_relations.flat_map { |relation| relation_track_ways(relation, ways) }
      .uniq { |way| way["id"] }
    seen_paths = Set.new
    node_paths = join_way_paths(member_ways).select { |path| seen_paths.add?(canonical_path_key(path)) }
    track_station_patterns = physical_station_patterns(node_paths, pattern_station_nodes)
    # Rendering geometry only: `extra_geometry_ways` is the track belonging to a direction
    # relation that select_service_relations folded away because it shares a group with the
    # selected relation, but which physically diverges from it (see the comment there) — e.g.
    # 首都机场线's one-way loop through T2 that the selected direction never visits. Union it in
    # here so the drawn line is complete. `track_station_patterns` above (and hence the routing
    # graph) is computed from `selected_relations` alone and is untouched by this.
    geometry_ways = (member_ways + extra_geometry_ways).uniq { |way| way["id"] }.sort_by { |way| way["id"] }
    geometry_seen_paths = Set.new
    geometry_node_paths = join_way_paths(geometry_ways)
      .select { |path| geometry_seen_paths.add?(canonical_path_key(path)) }
    coordinate_paths = geometry_node_paths.map do |path|
      coordinates = path.map { |node_id| nodes[node_id] }.compact.map do |coordinate|
        wgs84_to_gcj02(*coordinate)
      end
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

    relation_patterns = selected_relations.flat_map { |relation| ordered_relation_station_patterns(relation, elements_by_key) }
    service_patterns = unique_service_patterns(track_station_patterns + relation_patterns)

    {
      "id" => id,
      "logicalLineID" => id,
      "networkIdentity" => canonical_network,
      "routeReference" => route_reference,
      "name" => display_line_name(profiles, canonical, same_corridor),
      "nameEn" => LineNames.clean(canonical[:relation].dig("tags", "name:en")),
      "colorHex" => canonical_color(profiles, canonical),
      "stationIDs" => [],
      "servicePatterns" => service_patterns.map do |pattern|
        pattern.map { |name| station_id(city_id, name) }
      end,
      "paths" => coordinate_paths,
      "sourceRelationIDs" => direction_relations.map { |relation| relation["id"].to_s }.sort,
      "selectedSourceRelationIDs" => selected_relations.map { |relation| relation["id"].to_s }.sort,
      "servicePatternCount" => service_pattern_count
    }
  end.compact

  # Merge any lines that canonicalised to the same logical ID (e.g. unmerged direction
  # relations of an untagged line) so logical-line IDs stay unique — the routing graph keys
  # lines by ID and a duplicate key would crash it.
  lines = lines.group_by { |line| line["id"] }.map do |_id, group|
    next group.first if group.length == 1
    base = group.first
    base["servicePatterns"] = group.flat_map { |line| line["servicePatterns"] }.uniq
    base["paths"] = group.flat_map { |line| line["paths"] }
    base["sourceRelationIDs"] = group.flat_map { |line| line["sourceRelationIDs"] }.uniq.sort
    base["selectedSourceRelationIDs"] = group.flat_map { |line| line["selectedSourceRelationIDs"] }.uniq.sort
    base["servicePatternCount"] = base["selectedSourceRelationIDs"].length
    base
  end

  interchanges = build_interchanges(city, city_id, station_groups)

  stations = station_groups.map do |name_key, station|
    next if station["lineIDs"].empty?
    latitude = station["coordinates"].sum { |coordinate| coordinate[0] } / station["coordinates"].length
    longitude = station["coordinates"].sum { |coordinate| coordinate[1] } / station["coordinates"].length
    latitude, longitude = wgs84_to_gcj02(latitude, longitude)
    {
      "id" => station_id(city_id, name_key),
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
  emitted_source_relation_ids = lines.flat_map { |line| line["sourceRelationIDs"] }.to_set
  # Only own-city relations are expected to be emitted; relations rejected as belonging to
  # another city's system (see city_owns_line?) are intentionally absent and must not fail.
  missing_passenger_relations = passenger_relations.select do |relation|
    !emitted_source_relation_ids.include?(relation["id"].to_s) && relation_owned_by_city?(city, relation)
  end
  fail_with(
    "#{city[:name]} omitted passenger-bearing relations: " \
    "#{missing_passenger_relations.map { |relation| relation["id"] }.sort.join(", ")}"
  ) unless missing_passenger_relations.empty?
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
    "version" => "osm-#{snapshot.delete("-")}",
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
    "sourceSnapshot" => snapshot,
    "coordinateSystem" => "gcj02",
    "sourceURLs" => [SOURCE_URL, *OVERPASS_URLS.map(&:to_s)],
    "lines" => lines.sort_by { |line| line["name"] },
    "stations" => stations.sort_by { |station| station["name"] },
    "interchanges" => interchanges
  }
  report = canonicalization_report.merge(
    "cityID" => city_id,
    "sourceSnapshot" => snapshot,
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
  fail_with("unbuilt station filter (在建) test failed") unless unbuilt_station_name?("软件园（在建）")
  fail_with("unbuilt station filter (规划) test failed") unless unbuilt_station_name?("清华东路西口站（规划）")
  fail_with("unbuilt station filter (暂缓) test failed") unless unbuilt_station_name?("高家园(暂缓开通)")
  fail_with("unbuilt station false-positive test failed") if unbuilt_station_name?("城市规划展览馆")
  fail_with("unbuilt station parenthetical false-positive test failed") if unbuilt_station_name?("城市规划展览馆（A口）")
  fail_with("unbuilt station normal-name test failed") if unbuilt_station_name?("天通苑")
  fail_with("own-network line should be kept") unless city_owns_line?(CITIES.fetch("4403"), normalized("深圳地铁"), "地铁 1号线")
  fail_with("Hong Kong MTR line must not enter Shenzhen") if city_owns_line?(CITIES.fetch("4403"), normalized("港鐵 MTR"), "港鐵東鐵綫")
  fail_with("Suzhou line must not enter Shanghai") if city_owns_line?(CITIES.fetch("3100"), normalized("苏州轨道交通"), "11号线")
  fail_with("Shenzhen line must not enter Guangzhou") if city_owns_line?(CITIES.fetch("4401"), normalized("深圳地铁"), "深圳地铁13号线")
  fail_with("Guangdong intercity should be kept") unless city_owns_line?(
    CITIES.fetch("4401"), normalized("珠三角城际"), "广惠城际"
  )
  fail_with("Greater Bay intercity should be kept") unless city_owns_line?(
    CITIES.fetch("4406"), normalized("粤港澳大湾区城际铁路"), "广清城际"
  )
  # Intercity is admitted by name, not by opening `route=train`: mainline and high-speed
  # railway sharing the same bounding box must still be rejected.
  fail_with("national rail must not enter Guangzhou") if city_owns_line?(
    CITIES.fetch("4401"), normalized("中国铁路"), "广深铁路", mode: "train"
  )
  fail_with("high-speed rail must not enter Guangzhou") if city_owns_line?(
    CITIES.fetch("4401"), normalized("台灣高鐵"), "高鐵", mode: "train"
  )
  fail_with("own untagged line should be kept") unless city_owns_line?(CITIES.fetch("3100"), "unknown", "磁浮线")
  fail_with("foreign untagged line must be dropped") if city_owns_line?(CITIES.fetch("4401"), "unknown", "华为松山湖有轨电车1号线")
  fail_with("untagged urban line should be kept under allow_unknown") unless city_owns_line?(
    CITIES.fetch("6501"), "unknown", "1号线", mode: "subway"
  )
  fail_with("untagged heavy rail must not enter a city") if city_owns_line?(
    CITIES.fetch("6501"), "unknown", "13/14", mode: "train"
  )
  fail_with("direction suffix line-name test failed") unless passenger_line_name(
    "name" => "Light Rail 505 (A → B)"
  ) == "Light Rail 505"
  # The English label used to get a weaker reduction of its own, which is how names such as
  # "Light Rail 614P (Tuen Mun Ferry Pier" — cut mid-bracket by an arrow split — reached the app.
  fail_with("English line-name reduction test failed") unless
    LineNames.clean("Light Rail 614P (Tuen Mun Ferry Pier → Siu Hong)") == "Light Rail 614P"
  fail_with("nested-bracket run annotation test failed") unless
    LineNames.clean("呼和浩特地铁1号线（坝堰（机场）→伊利健康谷）") == "呼和浩特地铁1号线"
  fail_with("hyphenated line name must survive") unless
    LineNames.clean("臺北捷運 南港-板橋-土城線") == "臺北捷運 南港-板橋-土城線"
  fail_with("terminus pair test failed") unless LineNames.clean("常州地铁2号线 五一路-青枫公园") == "常州地铁2号线"
  fail_with("bare-ref line name test failed") unless
    passenger_line_name("name" => "1 窦官 - 小孟工业园", "ref" => "1") == "1号线"
  # An explicit `ref` always wins; the cases below all exercise the name fallback, which is what
  # keys line merging. Dropping a designation letter here fuses two different lines.
  fail_with("designation must survive ref inference") unless
    inferred_route_reference({}, "成都市域铁路S3资阳线") == "s3"
  fail_with("designation must not collide with a plain number") unless
    inferred_route_reference({}, "成都地铁3号线") == "3"
  fail_with("S-line designation test failed") unless
    inferred_route_reference({}, "南京地铁S1号线") == "s1"
  fail_with("tram designation test failed") unless
    inferred_route_reference({}, "有轨电车 亦庄T1线") == "t1"
  # No ASCII letter sits against the number, so these keep reducing to bare digits as before.
  fail_with("English line-number inference test failed") unless
    inferred_route_reference({}, "Metro Line 10") == "10"
  fail_with("numeric-suffix inference test failed") unless
    inferred_route_reference({}, "Light Rail 614P") == "614p"
  fail_with("explicit ref must win over the name") unless
    inferred_route_reference({ "ref" => "S3" }, "成都地铁3号线") == normalized("S3")
  joined = join_way_paths([
    { "id" => 1, "nodes" => [1, 2, 3] },
    { "id" => 2, "nodes" => [5, 4, 3] },
    { "id" => 3, "nodes" => [8, 9] }
  ])
  fail_with("way endpoint joining test failed") unless joined.any? { |path| path == [1, 2, 3, 4, 5] }
  fail_with("disconnected path test failed") unless joined.any? { |path| path == [8, 9] }
  xidan = wgs84_to_gcj02(39.9057386, 116.3682035)
  fail_with("WGS84 to GCJ-02 test failed") unless meters_between(xidan, [39.9071187, 116.3744198]) < 1
  # Apple's basemap is GCJ-02 across the whole of Greater China — the mainland, Hong Kong, Macau
  # and Taiwan alike — so no city is exempt. Hong Kong was previously left in WGS-84 on the
  # assumption that the SARs are surveyed unshifted; measured against MapKit that placed all 162
  # Hong Kong stations about 600 m off the basemap they are drawn on.
  hong_kong = [22.397643, 114.207797]
  fail_with("Hong Kong must convert to GCJ-02") if wgs84_to_gcj02(*hong_kong) == hong_kong
  fixture_elements = {
    "node:10" => { "tags" => { "name" => "A" } },
    "node:11" => { "tags" => { "name" => "B" } },
    "node:12" => { "tags" => { "name" => "C" } },
    "node:13" => { "tags" => { "name" => "D" } },
    "node:14" => { "tags" => { "name" => "E（规划）" } },
    "way:20" => { "tags" => { "name" => "A Platform 1" } },
    "way:21" => { "tags" => { "name" => "A Platform 2" } },
    "way:22" => { "tags" => { "name" => "Platform Only A" } },
    "way:23" => { "tags" => { "name" => "Platform Only B" } },
    "way:24" => { "tags" => { "name" => "F" } },
    "way:25" => { "tags" => { "name" => "G" } }
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
  unbuilt_stop_platform_fallback = {
    "id" => 8,
    "members" => [
      { "type" => "node", "ref" => 14, "role" => "stop" },
      { "type" => "way", "ref" => 24, "role" => "platform" },
      { "type" => "way", "ref" => 25, "role" => "platform" },
      { "type" => "way", "ref" => 100, "role" => "" }
    ]
  }
  fail_with("unbuilt-only stops blocked platform fallback") unless relation_station_names(unbuilt_stop_platform_fallback, fixture_elements) == %w[f g]
  fail_with("unbuilt-only stops blocked ordered platform fallback") unless ordered_relation_station_patterns(unbuilt_stop_platform_fallback, fixture_elements) == [%w[f g]]
  fail_with("stop-first station member test failed") unless relation_station_names(platform_direction.call(5, 20), fixture_elements) == %w[a b c]
  fail_with("unbuilt relation stop leaked into station pattern") unless relation_station_names(fixture_relation.call(8, [10, 14, 11], [100]), fixture_elements) == %w[a b]
  fail_with("unbuilt relation stop bridged ordered pattern") unless ordered_relation_station_patterns(fixture_relation.call(8, [10, 14, 11, 12], [100]), fixture_elements) == [%w[b c]]
  split_track_patterns = physical_station_patterns(
    [[1, 2, 3, 4]],
    {
      1 => [nil, "A"],
      2 => [nil, "E（规划）"],
      3 => [nil, "B"],
      4 => [nil, "C"]
    }
  )
  fail_with("unbuilt physical stop bridged track pattern") unless split_track_patterns == [%w[b c]]
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
  fail_with("light-rail eligibility test failed") unless supported_route_relation?("tags" => { "route" => "light_rail" })
  fail_with("monorail eligibility test failed") unless supported_route_relation?("tags" => { "route" => "monorail" })
  fail_with("tram eligibility test failed") unless supported_route_relation?("tags" => { "route" => "tram" })
  fail_with("networked urban train eligibility test failed") unless supported_route_relation?(
    "tags" => { "route" => "train", "network" => "Regional Rail" }
  )
  fail_with("passenger-class urban train eligibility test failed") unless supported_route_relation?(
    "tags" => { "route" => "train", "passenger" => "suburban" }
  )
  fail_with("stable operator-backed train eligibility test failed") unless supported_route_relation?(
    "tags" => { "route" => "train", "operator" => "Regional Operator", "wikidata" => "Q1" }
  )
  fail_with("unstructured train exclusion test failed") if supported_route_relation?(
    "tags" => { "route" => "train", "name" => "Intercity Train" }
  )
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
  directional_pair = [
    fixture_relation.call(31, [1, 2, 3], [100]).merge(
      "tags" => { "route" => "train", "network" => "Regional Rail", "from" => "A", "to" => "C" }
    ),
    fixture_relation.call(32, [3, 2], [101]).merge(
      "tags" => { "route" => "train", "network" => "Regional Rail", "from" => "C", "to" => "A" }
    )
  ]
  fail_with("terminal-based direction pairing test failed") unless passenger_service_patterns(
    directional_pair,
    fixture_elements
  ).length == 1
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
networks_by_city = {}
city_ids.each do |city_id|
  city = CITIES.fetch(city_id)
  source = fetch_source(city_id, city, refresh: !!refresh)
  network, report = build_network(city_id, city, source)
  reports << report
  networks_by_city[city_id] = network
end
# After every network is built, because a cross-pack interchange needs both halves' coordinates.
apply_cross_network_interchanges!(networks_by_city, city_ids)
city_ids.each do |city_id|
  network = networks_by_city.fetch(city_id)
  output = File.join(OUTPUT_DIR, "#{city_id}.json")
  File.write(output, "#{JSON.generate(network)}\n")
  points = network["lines"].sum { |line| line["paths"].sum(&:length) }
  puts "#{CITIES.fetch(city_id)[:name]}: lines=#{network["lines"].length} stations=#{network["stations"].length} points=#{points} -> #{output}"
end
report_output = File.join(REPORT_DIR, "canonicalization_report.json")
File.write(report_output, "#{JSON.pretty_generate({ "cities" => reports })}\n")
puts "Canonicalization report -> #{report_output}"
