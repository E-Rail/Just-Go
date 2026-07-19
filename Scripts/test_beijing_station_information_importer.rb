#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/beijing_station_information_importer"

class BeijingStationInformationImporterTest < Minitest::Test
  def test_maps_exact_names_and_explicit_aliases
    result = BeijingStationInformationImporter.import(
      index: index_fixture(
        ["1号线", [["未来科学城", 101], ["建国门", 102]]],
        ["2号线", [["建国门", 102], ["新站", 103]]]
      ),
      network: network_fixture(
        ["a", "未来科技城", "Weilai Kexuecheng"],
        ["b", "建国门", "Jianguomen"],
        ["c", "北京北", "Beijing North"]
      ),
      enforce_current_snapshot: false
    )

    assert_equal 2, result.fetch("mappedStationCount")
    assert_equal 2, result.fetch("stationPageCount")
    assert_equal 1, result.fetch("stationPageGapCount")
    future_science_city = result.fetch("stations").find { |station| station.fetch("stationID") == "a" }
    assert_equal ["未来科学城"], future_science_city.fetch("aliases")
    assert_equal "101", future_science_city.fetch("externalStationID")
    assert_equal 1, result.fetch("sourceOnlyStationCount")
    beijing_north = result.fetch("canonicalCoverageGaps").find {
      |station| station.fetch("stationName") == "北京北"
    }
    assert_equal "exactPage", beijing_north.fetch("informationStatus")
    assert_equal "stationInformation", beijing_north.fetch("resources").first.fetch("kind")
  end

  def test_rejects_unreviewed_canonical_gap
    error = assert_raises(BeijingStationInformationImporter::ImportError) do
      BeijingStationInformationImporter.import(
        index: index_fixture(["1号线", [["已知站", 101]]]),
        network: network_fixture(["a", "未知站", "Unknown"]),
        enforce_current_snapshot: false
      )
    end
    assert_includes error.message, "unreviewed canonical station gap"
  end

  def test_rejects_same_name_with_two_official_ids
    error = assert_raises(BeijingStationInformationImporter::ImportError) do
      BeijingStationInformationImporter.import(
        index: index_fixture(
          ["1号线", [["建国门", 101]]],
          ["2号线", [["建国门", 102]]]
        ),
        network: network_fixture(["a", "建国门", "Jianguomen"]),
        enforce_current_snapshot: false
      )
    end
    assert_includes error.message, "ambiguous official station names"
  end

  def test_rejects_conflicting_names_for_one_official_id
    error = assert_raises(BeijingStationInformationImporter::ImportError) do
      BeijingStationInformationImporter.parse_index(
        index_fixture(
          ["1号线", [["甲站", 101]]],
          ["2号线", [["乙站", 101]]]
        )
      )
    end
    assert_includes error.message, "conflicting names"
  end

  private

  def index_fixture(*lines)
    {
      "status" => 200,
      "message" => "成功",
      "data" => lines.map do |line_name, stations|
        {
          "lineCnName" => line_name,
          "stations" => stations.map do |name, external_id|
            { "stationName" => name, "accLocation" => external_id }
          end
        }
      end
    }
  end

  def network_fixture(*stations)
    {
      "cityID" => "1100",
      "stations" => stations.map do |station_id, name, name_en|
        { "id" => station_id, "name" => name, "nameEn" => name_en }
      end
    }
  end
end
