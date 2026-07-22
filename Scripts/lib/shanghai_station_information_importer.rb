# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "uri"

# Builds the reviewed Shanghai station catalog: canonical station ID -> the operator's own
# station identifier and landing page, and nothing else. Shanghai Metro publishes no open
# licence, so this mirrors the Beijing arrangement exactly — identifiers, names, aliases and
# URLs are committed; first/last trains, exits and facilities are never copied here and are
# fetched on the rider's own device at runtime. See DataPacks/RIGHTS.md.
module ShanghaiStationInformationImporter
  ImportError = Class.new(StandardError)

  INDEX_URL =
    "https://m.shmetro.com/core/shmetro/mdstationinfoback_new.ashx?act=getAllStations"
  DIRECTORY_URL = "https://service.shmetro.com/czxx/index.htm"
  DETAIL_PAGE_URL = "https://service.shmetro.com/czxx/index.htm"
  VERIFIED_AT = "2026-07-22"
  PROVIDER = "Shanghai Metro"

  # Operators other than Shanghai Metro. Their stations are in the canonical network because
  # they are rail the rider can ride, but shmetro.com does not publish them and linking a
  # rider to a station page that does not exist is worse than linking nothing.
  OTHER_OPERATOR_LINES = {
    "松江有轨电车1号线" => "songjiangTram",
    "松江有轨电车2号线" => "songjiangTram",
    "金山铁路" => "chinaRailwaySuburban",
    "上海浦东机场旅客捷运系统东线" => "airportPeopleMover",
    "上海浦东机场旅客捷运系统西线" => "airportPeopleMover"
  }.freeze

  # Shanghai Metro stations the official directory does not currently list. Reviewed
  # individually — an unreviewed gap is an error, not a silent omission.
  UNLISTED_METRO_STATIONS = %w[龙居路 江杨南路].freeze

  # Line 4 is a loop, so the official directory carries direction placeholders alongside real
  # stations. They are not places and must never become station references.
  SOURCE_DIRECTION_PLACEHOLDERS = ["内圈", "外圈", "内圈(宜山路)", "外圈(宜山路)"].freeze

  # Interpunct and bracket forms differ between the operator's directory and OSM
  # (U+00B7 vs U+30FB in 蟠祥路·国家会计学院, for one), which is a spelling difference rather
  # than a different place. Normalise both sides before matching, and keep the operator's
  # spelling as an alias whenever it differs from ours.
  SEPARATORS = /[·・･、\s()（）\[\]【】\-—―]/

  module_function

  def fetch_index(url: INDEX_URL)
    uri = URI(url)
    response = Net::HTTP.start(
      uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 15, read_timeout: 30
    ) do |http|
      http.get(uri.request_uri, "User-Agent" => "JustGo-DataImport/1.0", "Accept" => "application/json")
    end
    unless response.code == "200"
      raise ImportError, "Shanghai station index returned HTTP #{response.code}"
    end

    JSON.parse(response.body.to_s.force_encoding("UTF-8").scrub)
  rescue JSON::ParserError => error
    raise ImportError, "Shanghai station index returned invalid JSON: #{error.message}"
  end

  def import(index:, network:)
    source_stations = parse_index(index)
    canonical_stations, canonical_lines = parse_network(network)

    by_name = source_stations.group_by { |station| normalized(station.fetch("stationName")) }
    mapped_keys = {}
    mappings = []
    gaps = []

    canonical_stations.each do |station|
      matches = by_name[normalized(station.fetch("stationName"))]
      unless matches
        gaps << gap_record(station, canonical_lines)
        next
      end

      keys = matches.map { |match| match.fetch("externalStationID") }.sort
      representative = keys.first
      if mapped_keys.key?(representative)
        raise ImportError,
              "official station #{station.fetch('stationName')} maps to multiple canonical stations"
      end
      mapped_keys[representative] = station.fetch("stationID")

      source_name = matches.first.fetch("stationName")
      mappings << {
        "stationID" => station.fetch("stationID"),
        "stationName" => station.fetch("stationName"),
        "stationNameEn" => station.fetch("stationNameEn"),
        "aliases" => source_name == station.fetch("stationName") ? [] : [source_name],
        "externalStationID" => representative,
        # Every official key for this station, one per line it serves. The runtime provider
        # matches the operator's per-line service payload on these rather than on names.
        "lineStationIDs" => keys,
        "sourcePageURL" => detail_page_url(representative)
      }
    end

    mapped_key_set = mappings
      .flat_map { |station| station.fetch("lineStationIDs") }
      .each_with_object({}) { |key, seen| seen[key] = true }
    source_only = source_stations
      .reject { |station| mapped_key_set.key?(station.fetch("externalStationID")) }
      .map { |station| station.fetch("stationName") }
      .uniq
      .sort

    {
      "schemaVersion" => 1,
      "verifiedAt" => VERIFIED_AT,
      "sourceIndexURL" => INDEX_URL,
      "sourceIndexSHA256" => Digest::SHA256.hexdigest(JSON.generate(index)),
      "sourceDirectoryURL" => DIRECTORY_URL,
      "detailPageURL" => DETAIL_PAGE_URL,
      "provider" => PROVIDER,
      "canonicalStationCount" => canonical_stations.length,
      "sourceStationCount" => source_stations.length,
      "mappedStationCount" => mappings.length,
      "stationPageCount" => mappings.length,
      "stationPageGapCount" => canonical_stations.length - mappings.length,
      "stations" => mappings.sort_by { |station| station.fetch("stationID") },
      "canonicalCoverageGaps" => gaps.sort_by { |station| station.fetch("stationID") },
      "sourceOnlyStationCount" => source_only.length,
      "sourceOnlyStationNames" => source_only
    }
  end

  def parse_index(index)
    raise ImportError, "Shanghai station index contract is invalid" unless index.is_a?(Array)

    stations = index.map do |entry|
      unless entry.is_a?(Hash)
        raise ImportError, "Shanghai station index entry is not an object"
      end

      key = non_empty_string(entry["key"], "official station key")
      unless key.match?(/\A\d{4}\z/)
        raise ImportError, "official station key #{key.inspect} is not a four-digit reference"
      end

      {
        "externalStationID" => key,
        "stationName" => non_empty_string(entry["value"], "official station name for #{key}")
      }
    end

    placeholders = SOURCE_DIRECTION_PLACEHOLDERS.map { |name| normalized(name) }
    stations = stations.reject { |station| placeholders.include?(normalized(station.fetch("stationName"))) }
    raise ImportError, "Shanghai station index is empty" if stations.empty?

    keys = stations.map { |station| station.fetch("externalStationID") }
    raise ImportError, "duplicate official station key" unless keys.uniq.length == keys.length

    stations.sort_by { |station| station.fetch("externalStationID") }
  end

  def parse_network(network)
    unless network.is_a?(Hash) && network["cityID"] == "3100" &&
           network["stations"].is_a?(Array) && network["lines"].is_a?(Array)
      raise ImportError, "canonical Shanghai network contract is invalid"
    end

    line_names = network.fetch("lines").to_h do |line|
      [non_empty_string(line["id"], "canonical line ID"), non_empty_string(line["name"], "canonical line name")]
    end

    stations = network.fetch("stations").map do |station|
      station_id = non_empty_string(station["id"], "canonical station ID")
      station_name = non_empty_string(station["name"], "#{station_id} station name")
      name_en = station["nameEn"].to_s.strip
      {
        "stationID" => station_id,
        "stationName" => station_name,
        "stationNameEn" => name_en.empty? ? station_name : name_en,
        "lineNames" => Array(station["lineIDs"]).map { |id| line_names.fetch(id, id) }.sort
      }
    end

    ids = stations.map { |station| station.fetch("stationID") }
    raise ImportError, "duplicate canonical Shanghai station ID" unless ids.uniq.length == ids.length

    [stations, line_names]
  end

  def detail_page_url(external_station_id)
    uri = URI(DETAIL_PAGE_URL)
    uri.query = URI.encode_www_form("id" => external_station_id.to_s)
    uri.to_s
  end

  def gap_record(station, _canonical_lines)
    name = station.fetch("stationName")
    operators = station.fetch("lineNames").map { |line| OTHER_OPERATOR_LINES[line] }.compact.uniq
    reason = if !operators.empty?
      operators.length == 1 ? operators.first : "otherOperator"
    elsif UNLISTED_METRO_STATIONS.include?(name)
      "notListedByCurrentOfficialDirectory"
    else
      raise ImportError, "unreviewed canonical station gap: #{name}"
    end

    station.merge("reason" => reason)
  end

  def normalized(value)
    value.to_s.gsub(SEPARATORS, "")
  end

  def non_empty_string(value, label)
    result = value.to_s.strip
    raise ImportError, "#{label} is missing" if result.empty?

    result
  end
end
