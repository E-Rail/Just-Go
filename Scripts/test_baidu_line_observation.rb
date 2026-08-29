# frozen_string_literal: true

# Pins the rules that decide when a line page may show what the routing provider observed.
#
# A line page draws from the bundled OSM network, which is offline, free and the thing this app
# actually ships. The provider is there for the one question the pack cannot answer: is this still
# current. That answer is worth having only if it fails closed, because a wrong stop list on a line
# page is worse than no stop list at all.
#
#   1. Every ride in the plan must be rail *and* must be the line that was asked about. Routing
#      across a city returns whatever is fastest, and that is frequently a line nobody asked for.
#   2. A branch is the one case where two rides are still one line. Guangzhou 3号线 机场北 → 番禺广场
#      comes back as two steps both named 地铁3号线, because the rider really does change trains at
#      体育西路 without leaving the line. Those concatenate, and the join station appears once.
#   3. A ring line has no terminals to route between, and Baidu refuses trips between two adjacent
#      stations outright (北京 10号线, 700 m apart, returns zero routes). Both must yield nothing.
#   4. Stops arrive as boarding, every intermediate stop, then alighting, in that order. An exit
#      letter on the boarding station ("古城站(D西南口)") is normalised away like every other station
#      name in this codebase.
#
# Fixtures are synthetic, written to the wire shape. No provider response is committed here: their
# terms forbid storing what the service releases, and validate_runtime_data_policy.rb enforces it.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
SERVICE_SOURCE = File.read(
  File.join(ROOT, "Just-Go/Services/Transit/BaiduTripObservationService.swift"), encoding: "UTF-8"
)

# A Ruby mirror of `BaiduTripObservationService.observedLine(in:named:)`, so the rule is executable
# here rather than only described.
module LineExtraction
  module_function

  RAIL_DETAIL_TYPES = [1, 3, 12].freeze
  ROAD_DETAIL_TYPES = [0, 2, 6, 8, 10].freeze

  def normalized_station(name)
    trimmed = name.to_s.split(/[(（]/).first.to_s.strip
    trimmed = trimmed[0..-2] if trimmed.end_with?("站")
    trimmed
  end

  def line_token(name)
    name.to_s.gsub(/地铁|轨道交通|号线|線|line/i, "").strip
  end

  def lines_match?(left, right)
    return false if left.to_s.empty? || right.to_s.empty?
    line_token(left) == line_token(right)
  end

  def rail?(step)
    detail = step.dig("vehicle_info", "detail") || {}
    return false unless step.dig("vehicle_info", "type") == 3
    type = detail["type"]
    return true if RAIL_DETAIL_TYPES.include?(type)
    return false if ROAD_DETAIL_TYPES.include?(type)
    %w[地铁 轨道 轻轨 磁浮 有轨电车 APM MTR].any? { |marker| detail["name"].to_s.include?(marker) }
  end

  def append(stops, raw_name, location)
    name = normalized_station(raw_name)
    return if name.empty? || stops.last&.fetch(:name, nil) == name
    stops << { name: name, lat: location&.fetch("lat", 0.0) || 0.0, lng: location&.fetch("lng", 0.0) || 0.0 }
  end

  def observed_line(response, expected_name)
    (response.dig("result", "routes") || []).each do |route|
      rides = route.fetch("steps").flatten.reject { |step| (step.dig("vehicle_info", "type") || 5) == 5 }
      next if rides.empty?
      next unless rides.all? { |step| rail?(step) }

      details = rides.map { |step| step.dig("vehicle_info", "detail") }.compact
      next unless details.length == rides.length
      next unless details.all? { |detail| lines_match?(detail["name"], expected_name) }

      stops = []
      details.each do |detail|
        append(stops, detail["on_station"], nil)
        (detail["stop_info"] || []).each { |stop| append(stops, stop["stop_name"], stop["stop_location"]) }
        append(stops, detail["off_station"], nil)
      end
      next if stops.length < 2

      first = details.first
      return {
        name: first["name"],
        color: first["line_color"],
        direction: details.last["direct_text"],
        first_train: (first["first_time"].to_s.empty? ? nil : first["first_time"]),
        last_train: (first["last_time"].to_s.empty? ? nil : first["last_time"]),
        stops: stops
      }
    end
    nil
  end
end

def rail_step(name:, on:, off:, stops: [], color: nil, direction: nil, first: nil, last: nil, type: 1)
  {
    "vehicle_info" => {
      "type" => 3,
      "detail" => {
        "name" => name, "type" => type, "on_station" => on, "off_station" => off,
        "stop_info" => stops.map { |stop_name| { "stop_name" => stop_name, "stop_location" => { "lat" => 40.0, "lng" => 116.0 } } },
        "line_color" => color, "direct_text" => direction, "first_time" => first, "last_time" => last
      }
    }
  }
end

def walk_step(distance = 200)
  { "distance" => distance, "vehicle_info" => nil }
end

def response_with(*routes)
  { "result" => { "routes" => routes.map { |steps| { "steps" => steps } } } }
end

class BaiduLineObservationTest < Minitest::Test
  def test_single_line_ride_returns_every_stop_in_order
    response = response_with([[
      rail_step(
        name: "地铁18号线", on: "马连洼站", off: "天通苑东站",
        stops: %w[上地软件园 东北旺 龙泽西 回龙观西大街 文华路 回龙观东大街 霍营东 天通苑 太平庄],
        color: "#5554a2", direction: "天通苑东方向", first: "05:39", last: "22:49"
      )
    ]])
    line = LineExtraction.observed_line(response, "18号线")

    refute_nil line
    assert_equal "#5554a2", line[:color]
    assert_equal "天通苑东方向", line[:direction]
    assert_equal "05:39", line[:first_train]
    assert_equal "22:49", line[:last_train]
    assert_equal 11, line[:stops].length
    assert_equal "马连洼", line[:stops].first[:name]
    assert_equal "天通苑东", line[:stops].last[:name]
    assert_equal %w[马连洼 上地软件园 东北旺 龙泽西], line[:stops].first(4).map { |stop| stop[:name] }
  end

  def test_boarding_exit_letter_is_normalised_away
    response = response_with([[
      rail_step(name: "地铁1号线", on: "古城站(D西南口)", off: "国贸站", stops: %w[八角游乐园])
    ]])
    line = LineExtraction.observed_line(response, "1号线")
    assert_equal %w[古城 八角游乐园 国贸], line[:stops].map { |stop| stop[:name] }
  end

  def test_branch_on_the_same_line_concatenates_without_repeating_the_join
    response = response_with([[
      rail_step(name: "地铁3号线", on: "机场北站", off: "体育西路站", stops: %w[高增 人和]),
      walk_step(0),
      rail_step(name: "地铁3号线", on: "体育西路站", off: "番禺广场站", stops: %w[珠江新城 客村])
    ]])
    line = LineExtraction.observed_line(response, "3号线")

    refute_nil line
    names = line[:stops].map { |stop| stop[:name] }
    assert_equal %w[机场北 高增 人和 体育西路 珠江新城 客村 番禺广场], names
    assert_equal 1, names.count("体育西路")
  end

  def test_a_different_line_is_refused_even_when_it_rides_the_whole_way
    response = response_with([[
      rail_step(name: "地铁6号线", on: "海淀五路居站", off: "潞城站", stops: %w[慈寿寺 花园桥])
    ]])
    assert_nil LineExtraction.observed_line(response, "18号线")
  end

  def test_a_ride_that_changes_lines_is_refused
    response = response_with([[
      rail_step(name: "地铁2号线", on: "西直门站", off: "宣武门站", stops: %w[车公庄 复兴门]),
      walk_step,
      rail_step(name: "地铁4号线", on: "宣武门站", off: "西单站", stops: [])
    ]])
    assert_nil LineExtraction.observed_line(response, "2号线")
  end

  def test_a_bus_riding_a_line_shaped_name_is_refused
    response = response_with([[
      rail_step(name: "大兴机场大巴天通苑线", on: "天通苑站", off: "大兴机场站", stops: [], type: 2)
    ]])
    assert_nil LineExtraction.observed_line(response, "天通苑线")
  end

  def test_no_routes_yields_nothing
    assert_nil LineExtraction.observed_line({ "result" => { "routes" => [] } }, "10号线")
    assert_nil LineExtraction.observed_line({}, "10号线")
  end

  def test_a_walk_only_plan_yields_nothing
    assert_nil LineExtraction.observed_line(response_with([[walk_step(700)]]), "10号线")
  end

  # The provider's terms forbid storing what it releases, so a line lookup must live and die with
  # the session exactly as the trip lookup does.
  def test_line_lookups_are_never_written_to_disk
    %w[UserDefaults FileManager setCodable NSKeyedArchiver .write(to:].each do |marker|
      refute_includes SERVICE_SOURCE, marker, "#{marker} must not appear in the observation service"
    end
  end

  # A negative answer costs a call too. Caching it is what stops a ring line spending one every
  # time its page is opened.
  def test_a_refusal_is_cached_alongside_an_answer
    assert_includes SERVICE_SOURCE, "private var lineCache: [String: ObservedLine?]"
  end

  def test_the_line_name_guard_is_present_in_the_swift_source
    assert_includes SERVICE_SOURCE, "TransitLineMatching.linesMatch"
    assert_includes SERVICE_SOURCE, "rides.allSatisfy(\\.isRail)"
  end
end
