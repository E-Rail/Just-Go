# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "uri"

module BeijingStationInformationImporter
  INDEX_URL = "https://www.bjsubway.com/api/guanwang/v2/lineStations"
  DIRECTORY_URL = "https://www.bjsubway.com/station/"
  DETAIL_PAGE_URL = "https://www.bjsubway.com/station/siteinfo.html"
  VERIFIED_AT = "2026-07-17"

  CANONICAL_NAME_ALIASES = {
    "未来科技城" => "未来科学城",
    "未来科技城北" => "未来科学城北",
    "首都机场2号航站楼" => "2号航站楼",
    "首都机场3号航站楼" => "3号航站楼"
  }.freeze

  OUTSIDE_DIRECTORY_STATIONS = %w[
    三堡 东园 中仓 八达岭 北京东 北京北 南口 古北口 密云北 居庸关 康庄 延庆
    张辛 怀柔 怀柔北 昌平北 沙城 清河 牛栏山 良乡 通州西 雁栖湖 黄土店 黑山寺
  ].freeze
  UNLISTED_METRO_STATIONS = %w[八角游乐园 福寿岭 红庙 陶然桥].freeze
  CURRENT_SUBURBAN_STATIONS = %w[
    康庄 清河 怀柔北 中仓 北京东 八达岭 良乡 昌平北 沙城 北京北 雁栖湖
    密云北 牛栏山 黑山寺 通州西 南口 古北口 延庆 怀柔
  ].freeze
  NON_CURRENT_PASSENGER_STATIONS = %w[居庸关 三堡 黄土店 张辛 东园].freeze
  UNOPENED_METRO_STATIONS = %w[福寿岭 红庙 陶然桥].freeze
  EXPECTED_SOURCE_ONLY_STATIONS = %w[
    上地软件园 东北旺 回龙观西大街 文华路 朱房北 通运门 龙泽西
  ].freeze
  LEGACY_STATION_PAGES = {
    "八角游乐园" => "https://www.bjsubway.com/station/xltcx/line1/2013-08-19/5.html?sk=1"
  }.freeze
  SUBURBAN_RAIL_CONTEXT_URL =
    "https://jtw.beijing.gov.cn/sjtl/202111/t20211118_2540164.html"
  GAP_RESOURCE_OVERRIDES = {
    "北京北" => {
      "kind" => "stationInformation",
      "title" => "Beijing North Railway Station Guide",
      "targetURL" => "https://www.12306.cn/mormhweb/czyd_2143/bj/201001/t20100119_1582.html",
      "sourcePageURL" => "https://www.12306.cn/mormhweb/czyd_2143/bj/201001/t20100119_1582.html",
      "provider" => "China Railway 12306",
      "format" => "webPage"
    },
    "福寿岭" => {
      "kind" => "operatorInformation",
      "title" => "Fushouling Station Project Status",
      "targetURL" => "https://fgw.beijing.gov.cn/gzdt/fgzs/gzdt/202112/t20211224_2571614.htm",
      "sourcePageURL" => "https://fgw.beijing.gov.cn/gzdt/fgzs/gzdt/202112/t20211224_2571614.htm",
      "provider" => "Beijing Municipal Commission of Development and Reform",
      "format" => "webPage"
    },
    "陶然桥" => {
      "kind" => "operatorInformation",
      "title" => "Taoranqiao Station Opening Status",
      "targetURL" =>
        "https://www.beijing.gov.cn/hudong/yonghu/static/zdb/xinxiang/detail.html?searchCode=zdb16223326024872299813",
      "sourcePageURL" =>
        "https://www.beijing.gov.cn/hudong/yonghu/static/zdb/xinxiang/detail.html?searchCode=zdb16223326024872299813",
      "provider" => "Beijing Municipal Government",
      "format" => "webPage"
    },
    "红庙" => {
      "kind" => "operatorInformation",
      "title" => "Hongmiao Station Construction Notice",
      "targetURL" => "https://ggzyfw.beijing.gov.cn/jyxxggjtbyqs/20240516/4526775.html",
      "sourcePageURL" => "https://ggzyfw.beijing.gov.cn/jyxxggjtbyqs/20240516/4526775.html",
      "provider" => "Beijing Public Resources Trading Service Platform",
      "format" => "webPage"
    }
  }.freeze

  EXPECTED_CANONICAL_COUNT = 444
  EXPECTED_SOURCE_COUNT = 423
  EXPECTED_MAPPED_COUNT = 416

  class ImportError < StandardError; end

  module_function

  def fetch_index
    uri = URI(INDEX_URL)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    request["User-Agent"] = "Just-Go Beijing station-information importer"
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: true,
      open_timeout: 5,
      read_timeout: 15
    ) { |http| http.request(request) }
    raise ImportError, "#{INDEX_URL} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise ImportError, "Beijing station index returned invalid JSON: #{error.message}"
  end

  def import(index:, network:, enforce_current_snapshot: true)
    source_stations = parse_index(index)
    canonical_stations = parse_network(network)
    by_source_name = source_stations.group_by { |station| station.fetch("stationName") }
    ambiguous_names = by_source_name.select { |_name, records| records.length != 1 }
    unless ambiguous_names.empty?
      raise ImportError, "ambiguous official station names: #{ambiguous_names.keys.sort.join(', ')}"
    end

    mapped_source_ids = {}
    mappings = []
    gaps = []

    canonical_stations.each do |station|
      canonical_name = station.fetch("stationName")
      source_name = CANONICAL_NAME_ALIASES.fetch(canonical_name, canonical_name)
      source = by_source_name[source_name]&.first
      unless source
        gaps << gap_record(station)
        next
      end

      source_id = source.fetch("externalStationID")
      if mapped_source_ids.key?(source_id)
        raise ImportError, "official station #{source_name} maps to multiple canonical stations"
      end
      mapped_source_ids[source_id] = station.fetch("stationID")
      mappings << {
        "stationID" => station.fetch("stationID"),
        "stationName" => canonical_name,
        "stationNameEn" => station.fetch("stationNameEn"),
        "aliases" => source_name == canonical_name ? [] : [source_name],
        "externalStationID" => source_id,
        "sourcePageURL" => detail_page_url(source_id)
      }
    end

    source_only_names = source_stations.reject do |station|
      mapped_source_ids.key?(station.fetch("externalStationID"))
    end.map { |station| station.fetch("stationName") }.sort
    canonical_by_name = canonical_stations.to_h { |station| [station.fetch("stationName"), station] }
    legacy_pages = LEGACY_STATION_PAGES.each_with_object([]) do |(station_name, source_page_url), records|
      station = canonical_by_name[station_name]
      next unless station

      records << station.merge(
        "aliases" => [],
        "sourcePageURL" => source_page_url,
        "reason" => "officialLegacyPageWithoutCurrentStructuredRecord"
      )
    end

    result = {
      "schemaVersion" => 1,
      "verifiedAt" => VERIFIED_AT,
      "sourceIndexURL" => INDEX_URL,
      "sourceIndexSHA256" => Digest::SHA256.hexdigest(JSON.generate(index)),
      "sourceDirectoryURL" => DIRECTORY_URL,
      "detailPageURL" => DETAIL_PAGE_URL,
      "provider" => "Beijing Subway",
      "canonicalStationCount" => canonical_stations.length,
      "sourceStationCount" => source_stations.length,
      "mappedStationCount" => mappings.length,
      "stationPageCount" => mappings.length + legacy_pages.length,
      "stationPageGapCount" => canonical_stations.length - mappings.length - legacy_pages.length,
      "stations" => mappings.sort_by { |station| station.fetch("stationID") },
      "legacyStationPages" => legacy_pages.sort_by { |station| station.fetch("stationID") },
      "canonicalCoverageGaps" => gaps.sort_by { |station| station.fetch("stationID") },
      "sourceOnlyStationCount" => source_only_names.length
    }

    validate_current_snapshot!(result, source_only_names: source_only_names) if enforce_current_snapshot
    result
  end

  def parse_index(index)
    unless index.is_a?(Hash) && index["status"] == 200 && index["data"].is_a?(Array)
      raise ImportError, "Beijing station index contract is invalid"
    end

    by_external_id = {}
    index.fetch("data").each do |line|
      line_name = non_empty_string(line["lineCnName"], "line name")
      stations = line["stations"]
      raise ImportError, "#{line_name} has no station array" unless stations.is_a?(Array)

      stations.each do |station|
        name = non_empty_string(station["stationName"], "#{line_name} station name")
        external_id = station["accLocation"]
        unless external_id.is_a?(Integer) && external_id.positive?
          raise ImportError, "#{line_name} #{name} has invalid accLocation"
        end

        existing = by_external_id[external_id]
        if existing && existing.fetch("stationName") != name
          raise ImportError, "official station ID #{external_id} has conflicting names"
        end
        record = existing || {
          "externalStationID" => external_id.to_s,
          "stationName" => name,
          "lineNames" => []
        }
        record.fetch("lineNames") << line_name unless record.fetch("lineNames").include?(line_name)
        by_external_id[external_id] = record
      end
    end

    by_external_id.values.each { |station| station.fetch("lineNames").sort! }
    by_external_id.values.sort_by { |station| station.fetch("externalStationID") }
  end

  def parse_network(network)
    unless network.is_a?(Hash) && network["cityID"] == "1100" && network["stations"].is_a?(Array)
      raise ImportError, "canonical Beijing network contract is invalid"
    end

    stations = network.fetch("stations").map do |station|
      station_id = non_empty_string(station["id"], "canonical station ID")
      station_name = non_empty_string(station["name"], "#{station_id} station name")
      {
        "stationID" => station_id,
        "stationName" => station_name,
        "stationNameEn" => station["nameEn"].to_s.strip.empty? ? station_name : station["nameEn"].strip
      }
    end
    ids = stations.map { |station| station.fetch("stationID") }
    names = stations.map { |station| station.fetch("stationName") }
    raise ImportError, "duplicate canonical Beijing station ID" unless ids.uniq.length == ids.length
    raise ImportError, "duplicate canonical Beijing station name" unless names.uniq.length == names.length

    stations
  end

  def detail_page_url(external_station_id)
    uri = URI(DETAIL_PAGE_URL)
    uri.query = URI.encode_www_form("loc" => external_station_id.to_s)
    uri.to_s
  end

  def gap_record(station)
    name = station.fetch("stationName")
    reason = if OUTSIDE_DIRECTORY_STATIONS.include?(name)
      "outsideBeijingSubwayDirectory"
    elsif UNLISTED_METRO_STATIONS.include?(name)
      "notListedByCurrentOfficialDirectory"
    else
      raise ImportError, "unreviewed canonical station gap: #{name}"
    end
    station.merge(
      "reason" => reason,
      "informationStatus" => gap_information_status(name),
      "resources" => gap_resources(name)
    )
  end

  def gap_information_status(name)
    return "exactPage" if LEGACY_STATION_PAGES.key?(name) || name == "北京北"
    return "officialContextOnly" if CURRENT_SUBURBAN_STATIONS.include?(name)
    return "notOpenForPassengerService" if UNOPENED_METRO_STATIONS.include?(name)
    return "noCurrentPassengerService" if NON_CURRENT_PASSENGER_STATIONS.include?(name)

    raise ImportError, "unreviewed station-information status: #{name}"
  end

  def gap_resources(name)
    override = GAP_RESOURCE_OVERRIDES[name]
    return [override] if override
    return [] unless CURRENT_SUBURBAN_STATIONS.include?(name)

    [{
      "kind" => "operatorInformation",
      "title" => "Current Beijing Suburban Railway Lines and Stops",
      "targetURL" => SUBURBAN_RAIL_CONTEXT_URL,
      "sourcePageURL" => SUBURBAN_RAIL_CONTEXT_URL,
      "provider" => "Beijing Municipal Commission of Transport",
      "format" => "webPage"
    }]
  end

  def validate_current_snapshot!(result, source_only_names:)
    unless result.fetch("canonicalStationCount") == EXPECTED_CANONICAL_COUNT
      raise ImportError, "expected #{EXPECTED_CANONICAL_COUNT} canonical stations"
    end
    unless result.fetch("sourceStationCount") == EXPECTED_SOURCE_COUNT
      raise ImportError, "expected #{EXPECTED_SOURCE_COUNT} official station records"
    end
    unless result.fetch("mappedStationCount") == EXPECTED_MAPPED_COUNT
      raise ImportError, "expected #{EXPECTED_MAPPED_COUNT} canonical station mappings"
    end
    unless result.fetch("stationPageCount") == EXPECTED_MAPPED_COUNT + LEGACY_STATION_PAGES.length
      raise ImportError, "Beijing station-page coverage changed"
    end
    unless result.fetch("stationPageGapCount") ==
           EXPECTED_CANONICAL_COUNT - EXPECTED_MAPPED_COUNT - LEGACY_STATION_PAGES.length
      raise ImportError, "Beijing station-page gap count changed"
    end

    gap_names = result.fetch("canonicalCoverageGaps").map { |station| station.fetch("stationName") }.sort
    expected_gaps = (OUTSIDE_DIRECTORY_STATIONS + UNLISTED_METRO_STATIONS).sort
    raise ImportError, "canonical coverage gaps changed" unless gap_names == expected_gaps
    status_counts = result.fetch("canonicalCoverageGaps")
      .group_by { |station| station.fetch("informationStatus") }
      .transform_values(&:length)
    expected_status_counts = {
      "exactPage" => 2,
      "officialContextOnly" => 18,
      "notOpenForPassengerService" => 3,
      "noCurrentPassengerService" => 5
    }
    raise ImportError, "canonical gap review statuses changed" unless status_counts == expected_status_counts

    unless source_only_names == EXPECTED_SOURCE_ONLY_STATIONS.sort
      raise ImportError, "official-only station set changed"
    end
  end

  def non_empty_string(value, label)
    string = value.to_s.strip
    raise ImportError, "#{label} is empty" if string.empty?

    string
  end
end
