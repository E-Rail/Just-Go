#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/hangzhou_station_information_importer"

class HangzhouStationInformationImporterTest < Minitest::Test
  Importer = HangzhouStationInformationImporter

  def test_maps_a_plain_station_to_its_single_code
    result = Importer.import(
      operation: operation_fixture(["160", "候潮门"]),
      network: network_fixture(["a", "候潮门", "Houchaomen", ["4号线"]])
    )

    station = result.fetch("stations").fetch(0)
    assert_equal "160", station.fetch("externalStationID")
    assert_equal ["160"], station.fetch("lineStationIDs")
    assert_equal [], station.fetch("aliases")
    assert_equal 1, result.fetch("mappedStationCount")
    assert_equal 0, result.fetch("stationPageGapCount")
  end

  # The operator splits 火车东站 into a main hall and an east-plaza record while OSM models one
  # physical station. Both codes must survive, or the rider loses 19号线/6号线 entirely.
  def test_merges_the_split_east_railway_station_records_and_keeps_both_codes
    result = Importer.import(
      operation: operation_fixture(["76", "火车东站"], ["150", "火车东站（东广场）"]),
      network: network_fixture(
        ["a", "火车东站", "East Railway Station", ["1号线", "4号线", "6号线", "19号线"]]
      )
    )

    station = result.fetch("stations").fetch(0)
    assert_equal %w[76 150], station.fetch("lineStationIDs")
    # The lowest numeric code is pinned as the representative so a re-import cannot repoint it.
    assert_equal "76", station.fetch("externalStationID")
    assert_equal ["火车东站（东广场）"], station.fetch("aliases")
    assert_equal 0, result.fetch("sourceOnlyStationCount")
  end

  def test_maps_a_suffixed_operator_spelling_through_a_reviewed_override
    result = Importer.import(
      operation: operation_fixture(["12", "学院路站"]),
      network: network_fixture(["a", "学院路", "Xueyuan Road", ["2号线", "10号线"]])
    )

    station = result.fetch("stations").fetch(0)
    assert_equal "12", station.fetch("externalStationID")
    assert_equal ["学院路站"], station.fetch("aliases")
  end

  def test_records_a_haining_intercity_station_as_a_reviewed_gap
    result = Importer.import(
      operation: operation_fixture(["160", "候潮门"]),
      network: network_fixture(
        ["a", "候潮门", "Houchaomen", ["4号线"]],
        ["b", "盐官", "Yanguan", ["杭海城际铁路"]]
      )
    )

    assert_equal 1, result.fetch("stationPageGapCount")
    gap = result.fetch("canonicalCoverageGaps").fetch(0)
    assert_equal "盐官", gap.fetch("stationName")
    assert_equal "hainingIntercity", gap.fetch("reason")
  end

  def test_rejects_an_unreviewed_canonical_gap
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        operation: operation_fixture(["160", "候潮门"]),
        network: network_fixture(["a", "未审站", "Unreviewed", ["4号线"]])
      )
    end

    assert_match(/unreviewed canonical station gap/, error.message)
  end

  def test_rejects_one_code_claimed_by_two_canonical_stations
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        operation: operation_fixture(["160", "候潮门"]),
        network: network_fixture(
          ["a", "候潮门", "Houchaomen", ["4号线"]],
          ["b", "候潮门", "Houchaomen", ["4号线"]]
        )
      )
    end

    assert_match(/maps to multiple canonical stations/, error.message)
  end

  def test_rejects_a_station_code_naming_two_stations
    error = assert_raises(Importer::ImportError) do
      Importer.import(
        operation: operation_fixture(["160", "候潮门"], ["160", "文海南路"]),
        network: network_fixture(["a", "候潮门", "Houchaomen", ["4号线"]])
      )
    end

    assert_match(/names two stations/, error.message)
  end

  def test_reports_operator_stations_missing_from_the_network
    result = Importer.import(
      operation: operation_fixture(["160", "候潮门"], ["217", "创明路"]),
      network: network_fixture(["a", "候潮门", "Houchaomen", ["4号线"]])
    )

    assert_equal 1, result.fetch("sourceOnlyStationCount")
    assert_equal ["创明路"], result.fetch("sourceOnlyStationNames")
  end

  # The catalog is link-only: identifiers, names and aliases. Times and descriptions from the
  # operator payload must never reach the committed file.
  def test_carries_no_operator_content
    result = Importer.import(
      operation: operation_fixture(["160", "候潮门"]),
      network: network_fixture(["a", "候潮门", "Houchaomen", ["4号线"]])
    )

    serialized = JSON.generate(result)
    refute_match(/startTime|endTime|description|6:04|时刻表/, serialized)
  end

  def test_rejects_an_invalid_contract
    assert_raises(Importer::ImportError) do
      Importer.import(operation: { "data" => {} }, network: network_fixture(["a", "候潮门", "H", ["4号线"]]))
    end
  end

  private

  # `stationlist` is the operator's authoritative station index; `description` is present in the
  # real payload and included here so the link-only assertion above is meaningful.
  def operation_fixture(*stations)
    {
      "ok" => true,
      "data" => {
        "title" => "工作日时刻表",
        "stationlist" => stations.map do |code, name|
          {
            "stationCode" => code,
            "stationName" => name,
            "baiduStationName" => name,
            "description" => "#{name}站的官方介绍文字",
            "lineList" => ["4号线"]
          }
        end
      }
    }
  end

  def network_fixture(*stations)
    line_names = stations.flat_map { |entry| entry[3] }.uniq
    {
      "cityID" => "3301",
      "lines" => line_names.map { |name| { "id" => name, "name" => name } },
      "stations" => stations.map do |id, name, name_en, lines|
        { "id" => id, "name" => name, "nameEn" => name_en, "lineIDs" => lines }
      end
    }
  end
end
