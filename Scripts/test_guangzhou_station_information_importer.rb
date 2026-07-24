#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/guangzhou_station_information_importer"

class GuangzhouStationInformationImporterTest < Minitest::Test
  Importer = GuangzhouStationInformationImporter

  def test_maps_an_interchange_to_the_lowest_numeric_representative_code
    result = Importer.import(
      line_station: line_station_fixture(
        ["一号线", [["114", "体育西路", "Tiyu Xilu"]]],
        ["三号线", [["311", "体育西路", "Tiyu Xilu"]]]
      ),
      network: network_fixture(["a", "体育西路", "Tiyu Xilu", ["一号线", "三号线"]])
    )

    station = result.fetch("stations").fetch(0)
    # Any of a station's per-line codes resolves the whole station, so a single representative is
    # pinned — the lowest numeric one — and a re-import cannot silently repoint it.
    assert_equal "114", station.fetch("externalStationID")
    assert_equal [], station.fetch("aliases")
    assert_equal 1, result.fetch("mappedStationCount")
    assert_equal 0, result.fetch("stationPageGapCount")
  end

  def test_numeric_codes_sort_before_alphanumeric_ones
    result = Importer.import(
      line_station: line_station_fixture(
        ["广佛线", [["GF18", "西塱", "Xilang"]]],
        ["一号线", [["101", "西塱", "Xilang"]]],
        ["十号线", [["1001", "西塱", "Xilang"]]]
      ),
      network: network_fixture(["a", "西塱", "Xilang", ["一号线", "广佛线", "十号线"]])
    )

    assert_equal "101", result.fetch("stations").fetch(0).fetch("externalStationID")
  end

  def test_maps_a_variant_name_through_a_reviewed_override_and_keeps_the_operator_spelling
    result = Importer.import(
      line_station: line_station_fixture(
        ["三北线", [["330", "机场北（T2）", "Airport N.(T2)"]]]
      ),
      network: network_fixture(["a", "机场北", "Airport North", ["3号线"]])
    )

    station = result.fetch("stations").fetch(0)
    assert_equal "330", station.fetch("externalStationID")
    assert_equal ["机场北（T2）"], station.fetch("aliases")
    assert_equal 0, result.fetch("stationPageGapCount")
  end

  def test_classifies_reviewed_gaps_instead_of_linking_a_missing_reference
    result = Importer.import(
      line_station: line_station_fixture(["一号线", [["101", "西塱", "Xilang"]]]),
      network: network_fixture(
        ["a", "西塱", "Xilang", ["一号线"]],
        ["b", "机场南", "Airport South", ["3号线"]],
        ["c", "会展西", "Canton Fair Complex West", ["海珠有轨1号线"]]
      )
    )

    reasons = result.fetch("canonicalCoverageGaps").to_h { |gap| [gap.fetch("stationName"), gap.fetch("reason")] }
    assert_equal "operatorOmitsServiceTime", reasons.fetch("机场南")
    assert_equal "haizhuTram", reasons.fetch("会展西")
    assert_equal 2, result.fetch("stationPageGapCount")
  end

  def test_rejects_an_unreviewed_canonical_gap
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        line_station: line_station_fixture(["一号线", [["101", "西塱", "Xilang"]]]),
        network: network_fixture(
          ["a", "西塱", "Xilang", ["一号线"]],
          ["b", "未知站", "Unknown", ["一号线"]]
        )
      )
    end
    assert_match(/unreviewed canonical station gap: 未知站/, error.message)
  end

  def test_rejects_a_stale_override_whose_code_left_the_listing
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        line_station: line_station_fixture(["一号线", [["101", "西塱", "Xilang"]]]),
        network: network_fixture(
          ["a", "西塱", "Xilang", ["一号线"]],
          ["b", "机场北", "Airport North", ["3号线"]]
        )
      )
    end
    assert_match(/reviewed override 330 for 机场北 is not in the operator listing/, error.message)
  end

  def test_records_source_stations_the_canonical_network_is_missing
    result = Importer.import(
      line_station: line_station_fixture(
        ["一号线", [["101", "西塱", "Xilang"]]],
        ["佛山地铁3号线", [["F316", "潭洲会展", "Tanzhou"]]]
      ),
      network: network_fixture(["a", "西塱", "Xilang", ["一号线"]])
    )

    assert_equal 1, result.fetch("sourceOnlyStationCount")
    assert_equal ["潭洲会展"], result.fetch("sourceOnlyStationNames")
  end

  def test_rejects_a_show_code_that_names_two_stations
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        line_station: line_station_fixture(
          ["一号线", [["101", "西塱", "Xilang"]]],
          ["二号线", [["101", "嘉禾望岗", "Jiahewanggang"]]]
        ),
        network: network_fixture(["a", "西塱", "Xilang", ["一号线"]])
      )
    end
    assert_match(/show code 101 names two stations/, error.message)
  end

  private

  def line_station_fixture(*lines)
    {
      "businessObject" => lines.map do |line_name, stations|
        {
          "lineName" => line_name,
          "lineColor" => "edcf3dff",
          "stations" => stations.map do |code, name, name_en|
            { "stationShowCode" => code, "stationName" => name, "stationNameEn" => name_en }
          end
        }
      end
    }
  end

  def network_fixture(*stations)
    line_names = stations.flat_map { |entry| entry[3] }.uniq
    line_ids = line_names.to_h { |name| [name, "line-#{name}"] }
    {
      "cityID" => "4401",
      "lines" => line_names.map { |name| { "id" => line_ids.fetch(name), "name" => name } },
      "stations" => stations.map do |id, name, name_en, lines|
        {
          "id" => id,
          "name" => name,
          "nameEn" => name_en,
          "lineIDs" => lines.map { |line| line_ids.fetch(line) }
        }
      end
    }
  end
end
