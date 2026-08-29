# frozen_string_literal: true

# Pins the coordinate order of a cycling route's geometry, and the reason the leg exists at all.
#
# Baidu flips argument order between endpoints and between parameters on the same endpoint. The
# `origin` and `destination` this app sends are "lat,lng"; the `path` that comes back is
# "lng,lat;lng,lat;...". Reading the returned pair in the order it was sent puts a Beijing bike ride
# at latitude 116, which is not a latitude. That failure draws a line somewhere off the map instead
# of raising anything, which is the same silent shape as the GCJ-02 trap CLAUDE.md documents.
#
# Verified against the live endpoint while this was written: a path begins
# "116.39665,39.90937;..." for a ride starting near 39.9088,116.3974.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
SOURCE = File.read(
  File.join(ROOT, "Just-Go/Services/Map/BaiduRidingRouteProvider.swift"), encoding: "UTF-8"
)

# A Ruby mirror of `BaiduRidingRouteProvider.coordinates(fromPath:)`.
def coordinates(path)
  return [] if path.nil? || path.empty?

  path.split(";").map do |pair|
    parts = pair.split(",")
    next nil if parts.size < 2

    longitude = Float(parts[0], exception: false)
    latitude = Float(parts[1], exception: false)
    next nil if longitude.nil? || latitude.nil?

    { latitude: latitude, longitude: longitude }
  end.compact
end

class RidingPathTest < Minitest::Test
  BEIJING_PATH = "116.39665,39.90937;116.39646,39.90947;116.39600,39.91002"

  def test_longitude_comes_first_in_the_returned_path
    points = coordinates(BEIJING_PATH)

    assert_equal 3, points.size
    assert_in_delta 39.90937, points.first[:latitude], 0.00001
    assert_in_delta 116.39665, points.first[:longitude], 0.00001
  end

  def test_reading_the_pair_in_send_order_would_be_off_the_map
    # The bug this guards. Beijing sits near latitude 39.9; 116 is not a latitude anywhere.
    swapped = coordinates(BEIJING_PATH).first[:longitude]

    assert_operator swapped, :>, 90,
                    "if this ever parses below 90 the pair order has been silently swapped"
  end

  def test_malformed_pairs_are_dropped_rather_than_defaulted
    assert_empty coordinates("")
    assert_empty coordinates(nil)
    assert_empty coordinates("garbage;also,garbage")
    assert_equal 1, coordinates("116.4,39.9;incomplete").size
  end
end

class RidingSourceRulesTest < Minitest::Test
  def test_stairs_are_avoided_by_the_router_not_detected_afterwards
    assert_includes SOURCE, '(name: "road_prefer", value: "3")',
                    "3 is 不走逆行和楼梯; a route down a staircase is not a route a bike can take"
  end

  def test_electric_bikes_are_supported
    # The e-bike is what a great many people actually ride to the station, and it routes
    # differently: 8,289 m in 31 min against 9,094 m in 53 min on the same measured pair.
    assert_includes SOURCE, 'case .electric: return "1"',
                    "riding_type 1 is 电动车"
  end

  def test_a_cycling_leg_carries_no_walking_steps
    assert_includes SOURCE, "walkingDirections: nil",
                    "pedestrian instructions on a bike leg would be describing a different journey"
  end

  def test_absent_key_or_declined_route_falls_back_to_mapkit
    # With no key the composite must behave exactly as the app did before this existed.
    assert_includes SOURCE, "guard mode == .cycling, let riding else {"
    assert_includes SOURCE, "guard let route = await riding.route(from: from, to: to, vehicle: chosen) else {"
  end

  def test_nothing_is_persisted
    %w[UserDefaults.standard.set FileManager setCodable NSKeyedArchiver].each do |marker|
      refute_includes SOURCE, marker,
                      "#{marker} would persist provider data their terms forbid storing"
    end
  end
end
