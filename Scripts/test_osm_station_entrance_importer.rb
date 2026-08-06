#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/osm_station_entrance_importer"

class OSMStationEntranceImporterTest < Minitest::Test
  Importer = OSMStationEntranceImporter

  # Tiananmen West, in WGS-84 as OSM publishes it, and the same place in GCJ-02 as the app stores
  # it. The two differ by roughly 500 m, which is the whole reason this importer converts.
  WGS_LAT = 39.9053
  WGS_LON = 116.3859

  def test_normalize_keeps_only_entrance_nodes_and_used_fields
    payload = {
      "elements" => [
        { "type" => "node", "id" => 1, "lat" => WGS_LAT, "lon" => WGS_LON,
          "tags" => { "railway" => "subway_entrance", "ref" => "A", "name" => "天安门西A口",
                      "name:en" => "Tiananmen West Exit A", "wheelchair" => "yes",
                      "operator" => "北京地铁" } },
        { "type" => "node", "id" => 2, "lat" => WGS_LAT, "lon" => WGS_LON,
          "tags" => { "railway" => "station" } },
        { "type" => "way", "id" => 3, "tags" => { "railway" => "subway_entrance" } }
      ]
    }

    result = Importer.normalize(payload)

    assert_equal 1, result.length
    entrance = result.fetch(0)
    assert_equal "1", entrance.fetch("osmNodeID")
    assert_equal "A", entrance.fetch("ref")
    assert_equal "Tiananmen West Exit A", entrance.fetch("nameEn")
    assert_equal "yes", entrance.fetch("wheelchair")
    # Tags the app does not use are not carried into the committed file.
    refute entrance.key?("operator")
  end

  # The failure this guards is silent: without conversion every entrance lands ~600 m from its
  # own station, so nothing matches and the import produces an empty, plausible-looking result.
  def test_binds_entrances_only_after_converting_to_the_app_coordinate_frame
    gcj_lat, gcj_lon = GCJ02.from_wgs84(WGS_LAT, WGS_LON)
    network = network_fixture(["a", gcj_lat, gcj_lon])
    entrances = Importer.normalize(entrance_payload([1, WGS_LAT, WGS_LON, { "ref" => "A" }]))

    bindings, stats = Importer.bind(entrances: entrances, network: network)

    assert_equal 1, stats.fetch("boundCount")
    assert_equal ["a"], bindings.keys
    # The stored coordinate is the converted one, so it lines up with the station it is drawn beside.
    assert_in_delta gcj_lat, bindings.fetch("a").fetch(0).fetch("latitude"), 0.0005

    unconverted = network_fixture(["a", WGS_LAT, WGS_LON])
    _, raw_stats = Importer.bind(entrances: entrances, network: unconverted)
    assert_equal 0, raw_stats.fetch("boundCount"), "unconverted network must not match"
  end

  def test_drops_an_entrance_that_is_too_far_from_every_station
    far_lat, far_lon = GCJ02.from_wgs84(WGS_LAT + 0.05, WGS_LON)
    network = network_fixture(["a", far_lat, far_lon])
    entrances = Importer.normalize(entrance_payload([1, WGS_LAT, WGS_LON, { "ref" => "A" }]))

    bindings, stats = Importer.bind(entrances: entrances, network: network)

    assert_empty bindings
    assert_equal 1, stats.fetch("unmatchedCount")
  end

  # An entrance sitting between two stations belongs to neither by guesswork.
  def test_drops_an_entrance_that_two_stations_claim_equally
    gcj_lat, gcj_lon = GCJ02.from_wgs84(WGS_LAT, WGS_LON)
    network = network_fixture(["a", gcj_lat + 0.0009, gcj_lon], ["b", gcj_lat - 0.0009, gcj_lon])
    entrances = Importer.normalize(entrance_payload([1, WGS_LAT, WGS_LON, { "ref" => "A" }]))

    bindings, stats = Importer.bind(entrances: entrances, network: network)

    assert_empty bindings
    assert_equal 1, stats.fetch("ambiguousCount")
  end

  def test_document_is_deterministic
    gcj_lat, gcj_lon = GCJ02.from_wgs84(WGS_LAT, WGS_LON)
    network = network_fixture(["a", gcj_lat, gcj_lon])
    entrances = Importer.normalize(
      entrance_payload([2, WGS_LAT, WGS_LON, { "ref" => "B" }], [1, WGS_LAT, WGS_LON, { "ref" => "A" }])
    )

    first = Importer.document(city_id: "1100", entrances: entrances, network: network)
    second = Importer.document(city_id: "1100", entrances: entrances, network: network)

    assert_equal JSON.generate(first), JSON.generate(second)
    assert_equal %w[A B], first.fetch("stations").fetch("a").map { |e| e.fetch("ref") }
  end

  def test_rejects_an_invalid_payload
    assert_raises(Importer::ImportError) { Importer.normalize({ "elements" => nil }) }
  end

  def test_rejects_a_station_without_a_coordinate
    assert_raises(Importer::ImportError) do
      Importer.bind(entrances: [], network: { "stations" => [{ "id" => "a" }] })
    end
  end

  private

  def entrance_payload(*nodes)
    {
      "elements" => nodes.map do |id, lat, lon, tags|
        { "type" => "node", "id" => id, "lat" => lat, "lon" => lon,
          "tags" => { "railway" => "subway_entrance" }.merge(tags) }
      end
    }
  end

  def network_fixture(*stations)
    {
      "stations" => stations.map do |id, lat, lon|
        { "id" => id, "name" => id, "latitude" => lat, "longitude" => lon }
      end
    }
  end
end
