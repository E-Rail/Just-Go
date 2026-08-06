#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/shanghai_station_information_importer"

class ShanghaiStationInformationImporterTest < Minitest::Test
  Importer = ShanghaiStationInformationImporter

  def test_collects_every_line_key_for_an_interchange_station
    result = Importer.import(
      index: index_fixture(["0247", "陆家嘴"], ["1438", "陆家嘴"], ["0111", "莘庄"]),
      network: network_fixture(
        ["a", "陆家嘴", "Lujiazui", ["2号线", "14号线"]],
        ["b", "莘庄", "Xinzhuang", ["1号线"]]
      )
    )

    lujiazui = result.fetch("stations").find { |station| station.fetch("stationID") == "a" }
    assert_equal %w[0247 1438], lujiazui.fetch("lineStationIDs")
    # The lowest key is the stable representative, so a re-import cannot silently repoint the
    # station page at a different line's reference.
    assert_equal "0247", lujiazui.fetch("externalStationID")
    assert_equal "https://service.shmetro.com/czxx/index.htm?id=0247", lujiazui.fetch("sourcePageURL")
    assert_equal 2, result.fetch("mappedStationCount")
    assert_equal 0, result.fetch("sourceOnlyStationCount")
  end

  def test_matches_across_interpunct_spellings_and_keeps_the_official_one_as_an_alias
    result = Importer.import(
      index: index_fixture(["0233", "蟠祥路·国家会计学院"]),
      network: network_fixture(["a", "蟠祥路・国家会计学院", "Panxiang Road", ["2号线"]])
    )

    station = result.fetch("stations").fetch(0)
    assert_equal ["蟠祥路·国家会计学院"], station.fetch("aliases")
    assert_equal 0, result.fetch("stationPageGapCount")
  end

  def test_drops_loop_direction_placeholders_rather_than_treating_them_as_stations
    result = Importer.import(
      index: index_fixture(["0401", "上海体育馆"], ["0499", "内圈"], ["0498", "外圈(宜山路)"]),
      network: network_fixture(["a", "上海体育馆", "Shanghai Indoor Stadium", ["4号线"]])
    )

    assert_equal 1, result.fetch("sourceStationCount")
    assert_equal 0, result.fetch("sourceOnlyStationCount")
  end

  def test_classifies_other_operators_instead_of_linking_them_to_a_missing_page
    result = Importer.import(
      index: index_fixture(["0111", "莘庄"]),
      network: network_fixture(
        ["a", "莘庄", "Xinzhuang", ["1号线"]],
        ["b", "三新北路", "Sanxin North Road", ["松江有轨电车2号线"]],
        ["c", "金山卫", "Jinshanwei", ["金山铁路"]],
        ["d", "T1", "T1", ["上海浦东机场旅客捷运系统西线"]]
      )
    )

    reasons = result.fetch("canonicalCoverageGaps").to_h { |gap| [gap.fetch("stationName"), gap.fetch("reason")] }
    assert_equal "songjiangTram", reasons.fetch("三新北路")
    assert_equal "chinaRailwaySuburban", reasons.fetch("金山卫")
    assert_equal "airportPeopleMover", reasons.fetch("T1")
    assert_equal 3, result.fetch("stationPageGapCount")
  end

  def test_rejects_an_unreviewed_canonical_gap
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        index: index_fixture(["0111", "莘庄"]),
        network: network_fixture(
          ["a", "莘庄", "Xinzhuang", ["1号线"]],
          ["b", "未知站", "Unknown", ["1号线"]]
        )
      )
    end
    assert_match(/unreviewed canonical station gap: 未知站/, error.message)
  end

  def test_rejects_a_key_that_is_not_a_four_digit_reference
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        index: index_fixture(["111", "莘庄"]),
        network: network_fixture(["a", "莘庄", "Xinzhuang", ["1号线"]])
      )
    end
    assert_match(/four-digit reference/, error.message)
  end

  def test_records_official_stations_the_canonical_network_is_missing
    result = Importer.import(
      index: index_fixture(["0111", "莘庄"], ["0948", "金吉路"]),
      network: network_fixture(["a", "莘庄", "Xinzhuang", ["1号线"]])
    )

    assert_equal 1, result.fetch("sourceOnlyStationCount")
    assert_equal ["金吉路"], result.fetch("sourceOnlyStationNames")
  end

  private

  def index_fixture(*entries)
    entries.map { |key, name| { "key" => key, "value" => name } }
  end

  def network_fixture(*stations)
    line_names = stations.flat_map { |entry| entry[3] }.uniq
    line_ids = line_names.to_h { |name| [name, "line-#{name}"] }
    {
      "cityID" => "3100",
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
