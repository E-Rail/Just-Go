# frozen_string_literal: true

# Pins the handoff to bike and car legs, and pins the two ways it fails silently.
#
# Handing a leg to another app is the one place this project points away from itself, so the scope
# is deliberately narrow: the trains, the walk to the platform and the exit to use are what Just-Go
# is for. What it cannot do is live road navigation or hail a car, and those are exactly the legs it
# models worst — a cycling leg with no provider key is the pedestrian route re-timed, and a driving
# leg is MapKit's road route with no traffic, no restrictions and no parking.
#
# Neither failure below produces an error at build time or at run time. A scheme missing from
# LSApplicationQueriesSchemes makes canOpenURL answer false however installed the app is, so the
# button just never appears; and a destination with no web fallback does nothing at all for a rider
# who does not have it. Neither is testable on a simulator, because no simulator has any of these
# apps installed.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
HANDOFF = File.read(File.join(ROOT, "Just-Go/Services/Map/ExternalRouteHandoff.swift"), encoding: "UTF-8")
PLIST = File.read(File.join(ROOT, "Just-Go/Just-Go-Info.plist"), encoding: "UTF-8")
DETAIL = File.read(File.join(ROOT, "Just-Go/Views/Route/RouteDetailView.swift"), encoding: "UTF-8")

class ExternalRouteHandoffTest < Minitest::Test
  def queried_schemes
    HANDOFF.scan(/case \.(\w+): return "(\w+)"/).to_h { |destination, scheme| [destination, scheme] }
  end

  def declared_schemes
    block = PLIST[%r{<key>LSApplicationQueriesSchemes</key>\s*<array>(.*?)</array>}m, 1]
    refute_nil block, "LSApplicationQueriesSchemes is missing from the hand-written Info.plist"
    block.scan(%r{<string>([^<]+)</string>}).flatten
  end

  def test_every_queried_scheme_is_declared
    # INFOPLIST_KEY_* build settings are inert here: the target sets GENERATE_INFOPLIST_FILE = NO
    # and ships this file, which is the same trap that kept CFBundleDisplayName out of every build.
    queried_schemes.each_value do |scheme|
      assert_includes declared_schemes, scheme,
                      "#{scheme}:// is queried in code but not declared, so canOpenURL always says false"
    end
  end

  def test_nothing_is_declared_that_is_not_used
    # A queries entry the app never asks about is a capability claim it does not make.
    declared_schemes.each do |scheme|
      assert_includes queried_schemes.values, scheme,
                      "#{scheme} is declared in the plist but nothing queries it"
    end
  end

  def test_apple_maps_needs_no_scheme
    # Reached through MKMapItem, so it cannot be absent and needs no permission to ask about.
    assert_match(/case \.appleMaps: return nil/, HANDOFF)
  end

  def test_every_third_party_destination_has_a_web_fallback
    # The only path a rider without the app can use, and the only one exercisable without a device.
    %w[amap baiduMaps didi].each do |destination|
      web = HANDOFF[/static func webURL\(.*?\n    \}/m]
      refute_nil web
      arm = web[%r{case \.#{destination}:(.*?)(?=\n        case |\n        \}|\z)}m, 1]
      refute_nil arm, "#{destination} has no arm in webURL"
      assert_match(%r{"https://}, arm, "#{destination} has no https fallback")
    end
  end

  def test_coordinates_leave_in_the_frame_the_app_already_holds
    # Everything the app draws and measures is GCJ-02, and so is what all three services expect.
    # Converting would move the pin, so the requests say which frame they are in and send it raw.
    assert_includes HANDOFF, "coord_type=gcj02"
    assert_includes HANDOFF, "coordinate=gaode"
    assert_includes HANDOFF, "&dev=0"
    # And nothing converts them on the way out. A datum transform here would move the pin off the
    # door the trip just measured to.
    refute_match(/from_?wgs84|to_?wgs84|bd09|BD09|GCJ02\./, HANDOFF,
                 "no coordinate conversion belongs on this path")
  end

  def test_hailing_is_only_offered_for_a_car
    assert_match(/case \.didi: return mode == \.driving/, HANDOFF)
  end

  def test_walking_legs_are_never_handed_off
    # The walk to the platform is the part this app knows better than a road router does.
    assert_match(/segment\.type\.isAccessLeg, mode != \.walking/, DETAIL)
  end
end
