# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "uri"

# Builds the reviewed Hangzhou station catalog: canonical station ID -> the operator's own station
# references (its stationCodes), and nothing else. Hangzhou Metro publishes no open licence, so
# this mirrors the Beijing, Shanghai and Guangzhou arrangement exactly — identifiers, names and
# aliases are committed; first/last trains, station descriptions and line blurbs are never copied
# here and are fetched on the rider's own device at runtime. See DataPacks/RIGHTS.md.
#
# Unlike the other three, one call to /api/operation/all returns the whole network in a single
# payload, so the runtime fetches once and reads every station out of it. The catalog therefore
# carries the station's codes rather than a per-station page reference: the representative code
# (the lowest, pinned so a re-import cannot silently repoint it) plus every code the operator
# publishes for that physical station.
module HangzhouStationInformationImporter
  ImportError = Class.new(StandardError)

  OPERATION_ALL_URL = "https://www.hzmetro.com/api/operation/all"
  OPERATOR_URL = "https://www.hzmetro.com/"
  SITE_INQUIRY_URL = "https://www.hzmetro.com/operation/siteInquiry"
  VERIFIED_AT = "2026-07-28"
  PROVIDER = "Hangzhou Metro"
  CITY_ID = "3301"

  # Canonical stations the operator publishes under a variant name, or as more than one record.
  # Reviewed individually; the operator's own spellings are kept as aliases so the runtime identity
  # check accepts the response.
  #   火车东站 — the operator splits the interchange into two records, the main hall (1号线/4号线)
  #              and 火车东站（东广场） (19号线/6号线), while OSM models one physical station serving
  #              all four lines. Both codes are carried so the rider sees every line's service
  #              window rather than only the main hall's.
  #   学院路   — listed as "学院路站" in the operator's own station list.
  #   东新园   — listed as "东新园站".
  NAME_OVERRIDES = {
    "火车东站" => ["火车东站", "火车东站（东广场）"],
    "学院路" => ["学院路站"],
    "东新园" => ["东新园站"]
  }.freeze

  # Canonical stations with no operator reference. Reviewed individually — an unreviewed gap is an
  # error, not a silent omission. Every one belongs to 杭海城际铁路, the Hangzhou–Haining intercity
  # line, which is a separate operator and absent from this operator's network payload.
  REVIEWED_GAPS = %w[
    周王庙 斜桥 桐九公路 浙大国际校区 海宁高铁西站 海昌路 皮革城 盐官 许村 长安(东方学院) 长安东
  ].each_with_object({}) { |name, index| index[name] = "hainingIntercity" }.freeze

  # Bracket and separator forms differ between the operator's listing and OSM; normalise both
  # sides before matching and keep the operator's spelling as an alias whenever it differs.
  SEPARATORS = /[·・･、\s()（）\[\]【】\-—―]/

  module_function

  def fetch_operation_all(url: OPERATION_ALL_URL)
    uri = URI(url)
    response = Net::HTTP.start(
      uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 15, read_timeout: 60
    ) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      # The endpoint answers 502 without a same-origin Referer/Origin pair.
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request["Accept"] = "application/json"
      request["Origin"] = OPERATOR_URL.chomp("/")
      request["Referer"] = SITE_INQUIRY_URL
      request["User-Agent"] = "JustGo-DataImport/1.0"
      request.body = ""
      http.request(request)
    end
    unless response.code == "200"
      raise ImportError, "Hangzhou operation/all returned HTTP #{response.code}"
    end

    JSON.parse(response.body.to_s.force_encoding("UTF-8").scrub)
  rescue JSON::ParserError => error
    raise ImportError, "Hangzhou operation/all returned invalid JSON: #{error.message}"
  end

  def import(operation:, network:)
    source_by_name, source_codes = parse_operation(operation)
    canonical_stations = parse_network(network)

    used_codes = {}
    mappings = []
    gaps = []
    mapped_source_names = {}

    canonical_stations.each do |station|
      name = station.fetch("stationName")
      codes, source_names = resolve(name, source_by_name, source_codes)

      if codes.empty?
        gaps << gap_record(station)
        next
      end

      codes.each do |code|
        if used_codes.key?(code)
          raise ImportError,
                "Hangzhou station reference #{code} maps to multiple canonical stations"
        end
        used_codes[code] = station.fetch("stationID")
      end
      source_names.each { |source_name| mapped_source_names[source_name] = true }

      mappings << {
        "stationID" => station.fetch("stationID"),
        "stationName" => name,
        "stationNameEn" => station.fetch("stationNameEn"),
        "aliases" => (source_names - [name]).sort,
        "externalStationID" => codes.first,
        "lineStationIDs" => codes
      }
    end

    source_only = source_codes.values
      .map { |entry| entry.fetch("name") }
      .reject { |source_name| mapped_source_names.key?(source_name) }
      .uniq
      .sort

    {
      "schemaVersion" => 1,
      "verifiedAt" => VERIFIED_AT,
      "sourceIndexURL" => OPERATION_ALL_URL,
      "sourceIndexSHA256" => Digest::SHA256.hexdigest(JSON.generate(operation)),
      "operatorURL" => OPERATOR_URL,
      "siteInquiryURL" => SITE_INQUIRY_URL,
      "provider" => PROVIDER,
      "canonicalStationCount" => canonical_stations.length,
      "sourceStationCount" => source_codes.length,
      "mappedStationCount" => mappings.length,
      "stationPageCount" => mappings.length,
      "stationPageGapCount" => canonical_stations.length - mappings.length,
      "stations" => mappings.sort_by { |station| station.fetch("stationID") },
      "canonicalCoverageGaps" => gaps.sort_by { |station| station.fetch("stationID") },
      "sourceOnlyStationCount" => source_only.length,
      "sourceOnlyStationNames" => source_only
    }
  end

  # Returns [station_codes, operator_display_names] for a canonical station name, or [[], []] when
  # nothing in the operator's listing covers it. Codes are sorted so the first is the pinned
  # representative.
  def resolve(name, source_by_name, source_codes)
    if (override = NAME_OVERRIDES[name])
      entries = override.map do |source_name|
        source_by_name[normalized(source_name)]
          &.find { |candidate| candidate.fetch("name") == source_name } ||
          raise(ImportError, "reviewed override #{source_name} for #{name} is not in the operator listing")
      end
      return [entries.map { |entry| entry.fetch("code") }.sort_by { |code| code_sort_key(code) },
              entries.map { |entry| entry.fetch("name") }]
    end

    matches = source_by_name[normalized(name)]
    return [[], []] unless matches

    codes = matches.map { |match| match.fetch("code") }.sort_by { |code| code_sort_key(code) }
    [codes, matches.map { |match| match.fetch("name") }]
  end

  # Numeric codes sort before alphanumeric ones, and numerically among themselves, so the
  # representative is a stable, human-obvious "lowest" reference ("76" before "150").
  def code_sort_key(code)
    code.match?(/\A\d+\z/) ? [0, code.to_i, code] : [1, 0, code]
  end

  def parse_operation(payload)
    unless payload.is_a?(Hash) && payload["data"].is_a?(Hash) &&
           payload.fetch("data")["stationlist"].is_a?(Array)
      raise ImportError, "Hangzhou operation/all contract is invalid"
    end

    source_codes = {}
    payload.fetch("data").fetch("stationlist").each do |station|
      raise ImportError, "Hangzhou station entry is not an object" unless station.is_a?(Hash)

      code = non_empty_string(station["stationCode"], "station code")
      name = non_empty_string(station["stationName"], "station name for #{code}")
      existing = source_codes[code]
      if existing && existing.fetch("name") != name
        raise ImportError, "station code #{code} names two stations: #{existing.fetch('name')} / #{name}"
      end
      source_codes[code] ||= { "code" => code, "name" => name }
    end
    raise ImportError, "Hangzhou station listing is empty" if source_codes.empty?

    source_by_name = source_codes.values.each_with_object({}) do |entry, index|
      (index[normalized(entry.fetch("name"))] ||= []) << entry
    end
    [source_by_name, source_codes]
  end

  def parse_network(network)
    unless network.is_a?(Hash) && network["cityID"] == CITY_ID &&
           network["stations"].is_a?(Array) && network["lines"].is_a?(Array)
      raise ImportError, "canonical Hangzhou network contract is invalid"
    end

    line_names = network.fetch("lines").to_h do |line|
      [non_empty_string(line["id"], "canonical line ID"),
       non_empty_string(line["name"], "canonical line name")]
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
    raise ImportError, "duplicate canonical Hangzhou station ID" unless ids.uniq.length == ids.length

    stations
  end

  def gap_record(station)
    name = station.fetch("stationName")
    reason = REVIEWED_GAPS[name]
    raise ImportError, "unreviewed canonical station gap: #{name}" unless reason

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
