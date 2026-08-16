# frozen_string_literal: true

# Pins the rules that make an observed fare honest to show.
#
# A fare is the one number on a route card a rider will act on with their own money, and it comes
# from a provider that priced *its* route, not ours. Three rules keep that defensible, and all three
# are the kind that look like needless caution until someone removes one:
#
#   1. A fare attaches only when the boarding and alighting stations match. Chinese metro tariffs
#      are charged on the entry and exit gates rather than the path between them, which is the whole
#      reason a fare observed on a different path is still this route's fare. Drop the station-pair
#      check and it stops being true.
#   2. Only rail-only plans are priced. A bus-only plan reports ticket_type 1 (rail) with a price of
#      0 next to its real bus fare, so reading the rail entry off any plan would return ¥0 with
#      total confidence.
#   3. Everything absent stays absent. No provider answer, no fare, no taxi block, or a city the
#      provider does not cover (Hong Kong returns zero transit routes) must all render nothing.
#
# The fixtures below are synthetic, hand-written to the wire shape. No provider response is
# committed to this repo: their terms forbid storing what the service releases, and
# validate_runtime_data_policy.rb enforces it.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
SOURCE = File.read(
  File.join(ROOT, "Just-Go/Services/Transit/BaiduTripObservationService.swift"), encoding: "UTF-8"
)
PLANNING_SOURCE = File.read(
  File.join(ROOT, "Just-Go/Services/Transit/RoutePlanningService.swift"), encoding: "UTF-8"
)

# A Ruby mirror of the extraction rules in BaiduTripObservationService, so the rules themselves are
# executable here rather than only asserted about.
module Extraction
  module_function

  def normalized_station(name)
    trimmed = name.to_s.split(/[(（]/).first.to_s.strip
    trimmed = trimmed[0..-2] if trimmed.end_with?("站")
    trimmed.strip
  end

  RAIL_DETAIL_TYPES = [1, 3, 12].freeze
  ROAD_DETAIL_TYPES = [0, 2, 6, 8, 10].freeze

  def rail_line?(name, detail_type)
    return true if RAIL_DETAIL_TYPES.include?(detail_type)
    return false if ROAD_DETAIL_TYPES.include?(detail_type)

    markers = %w[地铁 轨道 轻轨 磁浮 磁悬浮 有轨电车 APM MTR]
    markers.any? { |marker| name.to_s.include?(marker) } || name.to_s.downcase.include?("line")
  end

  def rail?(step)
    step.dig("vehicle_info", "type") == 3 &&
      rail_line?(step.dig("vehicle_info", "detail", "name"),
                 step.dig("vehicle_info", "detail", "type"))
  end

  def rail_fare(route)
    vehicles = route.fetch("steps").reject { |step| step.dig("vehicle_info", "type").nil? }
    return nil if vehicles.empty?
    return nil unless vehicles.all? { |step| rail?(step) }

    rail_entry = (route["price_detail"] || {})
                 .then { |detail| detail.is_a?(Array) ? detail : [] }
                 .find { |entry| entry["ticket_type"] == 1 }
    yuan = rail_entry ? rail_entry["ticket_price"] : route["price"]
    return nil if yuan.nil? || yuan <= 0

    {
      boarding: normalized_station(vehicles.first.dig("vehicle_info", "detail", "on_station")),
      alighting: normalized_station(vehicles.last.dig("vehicle_info", "detail", "off_station")),
      yuan: yuan
    }
  end

  def night_window(label)
    hours = label.to_s.scan(/(\d{1,2}):\d{2}/).flatten.map(&:to_i)
    return nil if hours.size < 2 || hours[0] > 23 || hours[1] > 23

    { start: hours[0], finish: hours[1] }
  end

  def taxi(block)
    rows = (block&.fetch("detail", []) || []).select { |row| row["total_price"].to_f.positive? }
    return nil if rows.empty?

    night = rows.find { |row| row["desc"].to_s.include?("夜") }
    day = rows.find { |row| !row["desc"].to_s.include?("夜") }
    return { day: rows.first["total_price"], night: rows.first["total_price"], window: nil } if
      night.nil? || day.nil?

    { day: day["total_price"], night: night["total_price"], window: night_window(night["desc"]) }
  end

  def in_night?(window, hour)
    return false if window.nil?

    if window[:start] <= window[:finish]
      hour >= window[:start] && hour < window[:finish]
    else
      hour >= window[:start] || hour < window[:finish]
    end
  end
end

def transit_step(line:, on:, off:, detail_type:)
  {
    "vehicle_info" => {
      "type" => 3,
      "detail" => { "name" => line, "type" => detail_type, "on_station" => on, "off_station" => off }
    }
  }
end

# detail.type 1 is 地铁·轻轨.
def rail_step(line:, on:, off:, detail_type: 1)
  transit_step(line: line, on: on, off: off, detail_type: detail_type)
end

# detail.type 0 is 普通公交.
def bus_step(line:, on:, off:, detail_type: 0)
  transit_step(line: line, on: on, off: off, detail_type: detail_type)
end

class FareAttributionTest < Minitest::Test
  def test_rail_only_plan_is_priced_from_its_gates
    route = {
      "price" => 6, "price_detail" => [{ "ticket_type" => 1, "ticket_price" => 6 }],
      "steps" => [rail_step(line: "地铁1号线八通线", on: "苹果园站(D苹果园交通枢纽口)", off: "国贸站")]
    }
    fare = Extraction.rail_fare(route)

    assert_equal 6, fare[:yuan]
    # The exit letter and the 站 suffix both come off, because the graph names neither.
    assert_equal "苹果园", fare[:boarding]
    assert_equal "国贸", fare[:alighting]
  end

  def test_bus_plan_reporting_zero_rail_fare_is_never_priced
    # The trap this rule exists for. Reading ticket_type 1 off this plan yields ¥0.
    route = {
      "price" => 2,
      "price_detail" => [{ "ticket_type" => 1, "ticket_price" => 0 }, { "ticket_type" => 0, "ticket_price" => 2 }],
      "steps" => [bus_step(line: "105路", on: "西单路口南站", off: "西直门内站")]
    }

    assert_nil Extraction.rail_fare(route)
  end

  def test_mixed_rail_and_bus_plan_is_not_priced
    route = {
      "price" => 8,
      "price_detail" => [{ "ticket_type" => 1, "ticket_price" => 6 }, { "ticket_type" => 0, "ticket_price" => 2 }],
      "steps" => [
        rail_step(line: "地铁6号线", on: "苹果园站", off: "呼家楼站"),
        bus_step(line: "98路", on: "呼家楼站", off: "大北窑北站")
      ]
    }

    assert_nil Extraction.rail_fare(route),
               "a plan the app would never produce must not lend its fare to one it would"
  end

  def test_cross_city_plan_falls_back_to_the_route_total
    # price_detail is empty across cities, where the route total is the whole fare.
    route = {
      "price" => 41, "price_detail" => [],
      "steps" => [rail_step(line: "大兴机场线", on: "天通苑站(D口)", off: "大兴机场站", detail_type: 12)]
    }

    assert_equal 41, Extraction.rail_fare(route)[:yuan]
  end

  def test_airport_rail_is_rail_and_the_airport_coach_is_not
    # Both end in 线 and neither contains 地铁, so the name cannot separate them. Baidu's code can:
    # 12 is 机场轨道快线, 2 is a coach. Before this rule the express read as a bus and its
    # interchanges were never measured.
    assert Extraction.rail_line?("大兴机场线", 12)
    refute Extraction.rail_line?("大兴机场大巴天通苑线", 2)
    refute Extraction.rail_line?("快速直达专线168路", 10)
  end

  def test_an_undocumented_code_falls_back_to_the_name
    assert Extraction.rail_line?("地铁1号线", 99)
    refute Extraction.rail_line?("105路", 99)
  end

  def test_a_plan_with_no_vehicles_is_not_priced
    assert_nil Extraction.rail_fare({ "price" => 3, "steps" => [{}] })
  end
end

class TaxiFallbackTest < Minitest::Test
  BEIJING = { "detail" => [
    { "desc" => "白天(05:00-23:00)", "total_price" => 84 },
    { "desc" => "夜间(23:00-05:00)", "total_price" => 98 }
  ] }.freeze

  CHENGDU = { "detail" => [
    { "desc" => "白天(06:00-23:00)", "total_price" => 44 },
    { "desc" => "夜间(23:00-06:00)", "total_price" => 51 }
  ] }.freeze

  FLAT = { "detail" => [{ "desc" => "全天", "total_price" => 127 }] }.freeze

  def test_night_window_is_read_from_the_city_not_assumed
    # Beijing's day starts at 05:00 and Chengdu's at 06:00. Hardcoding either quotes the wrong
    # tariff in the other city, which is the entire reason the label is parsed.
    beijing = Extraction.taxi(BEIJING)
    chengdu = Extraction.taxi(CHENGDU)

    assert_equal({ start: 23, finish: 5 }, beijing[:window])
    assert_equal({ start: 23, finish: 6 }, chengdu[:window])

    # 05:30 is daytime in Beijing and still night in Chengdu.
    refute Extraction.in_night?(beijing[:window], 5)
    assert Extraction.in_night?(chengdu[:window], 5)
  end

  def test_night_window_wraps_midnight
    window = Extraction.taxi(BEIJING)[:window]

    assert Extraction.in_night?(window, 23)
    assert Extraction.in_night?(window, 0)
    assert Extraction.in_night?(window, 4)
    refute Extraction.in_night?(window, 12)
  end

  def test_one_flat_rate_has_no_night_window
    flat = Extraction.taxi(FLAT)

    assert_nil flat[:window]
    assert_equal flat[:day], flat[:night]
  end

  def test_absent_taxi_block_yields_nothing
    # The field is undocumented in the transit reference and served anyway. When it stops being
    # served the app must stop mentioning taxis, not crash and not invent one.
    assert_nil Extraction.taxi(nil)
    assert_nil Extraction.taxi({ "detail" => [] })
    assert_nil Extraction.taxi({ "detail" => [{ "desc" => "白天", "total_price" => 0 }] })
  end
end

class UncoveredCityTest < Minitest::Test
  def test_a_city_the_provider_does_not_route_yields_no_fare
    # Hong Kong returns zero transit routes. Every derived fact must be empty rather than defaulted.
    routes = []

    assert_empty routes.map { |route| Extraction.rail_fare(route) }.compact
  end
end

class SourceRulesTest < Minitest::Test
  def test_station_pair_match_requires_both_ends
    assert_includes SOURCE, "func matches(boarding: String, alighting: String)",
                    "a fare must be matched on the gate pair, which is what it is charged on"
    assert_includes SOURCE, "TransitLineMatching.stationsMatch(boardingStationName, boarding)"
    assert_includes SOURCE, "TransitLineMatching.stationsMatch(alightingStationName, alighting)"
  end

  def test_planning_discards_an_unmatched_fare
    assert_includes PLANNING_SOURCE, "observed.railFares.first(where: {",
                    "pricing must look the fare up by station pair rather than taking the first one"
  end

  def test_only_rail_only_plans_are_priced
    assert_includes SOURCE, "vehicles.allSatisfy(\\.isRail)",
                    "pricing a plan containing a bus reads a rail fare of 0"
  end

  def test_unpriced_routes_sink_in_the_cheapest_sort
    # Sorting an unpriced route as free would float the one thing the app does not know to the top.
    assert_includes PLANNING_SOURCE, "case (.some, nil):"
    assert_includes PLANNING_SOURCE, "case (nil, .some):"
  end

  def test_nothing_baidu_derived_is_persisted
    %w[UserDefaults FileManager setCodable NSKeyedArchiver].each do |marker|
      refute_includes SOURCE, marker,
                      "#{marker} would persist provider data their terms forbid storing"
    end
  end
end
