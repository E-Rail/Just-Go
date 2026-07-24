# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "uri"

# Builds the reviewed Guangzhou station catalog: canonical station ID -> the operator's own
# station reference (its stationShowCode), and nothing else. Guangzhou Metro publishes no open
# licence, so this mirrors the Beijing and Shanghai arrangement exactly — identifiers, names and
# aliases are committed; first/last trains are never copied here and are fetched on the rider's
# own device at runtime. See DataPacks/RIGHTS.md.
#
# Unlike Shanghai, one call to serviceTime/list/{stationShowCode} returns every line serving that
# physical station, so a single representative code per station is enough. The representative is
# the lowest code (numeric before alphanumeric), pinned so a re-import cannot silently repoint it.
module GuangzhouStationInformationImporter
  ImportError = Class.new(StandardError)

  LINE_STATION_URL = "https://apis.gzmtr.com/app-map/metroweb/linestation"
  SERVICE_TIME_URL = "https://apis.gzmtr.com/app-map/serviceTime/list/{stationShowCode}"
  OPERATOR_URL = "https://www.gzmtr.com/"
  VERIFIED_AT = "2026-07-23"
  PROVIDER = "Guangzhou Metro"

  # Canonical stations the operator lists under a variant name — a parenthetical suffix, or a
  # decomposed character the operator writes with base radicals. Reviewed individually; the
  # representative showCode is pinned and the operator's own spelling is kept as an alias so the
  # runtime identity check accepts the service response.
  #   𧒽岗  — operator writes "虫雷 岗" on the Guangfo Line (GF13).
  #   庆盛  — operator writes "庆盛（南沙北站）" on Line 4 (411).
  #   机场北 — operator writes "机场北（T2）" on the Line 3 north branch (330).
  NAME_OVERRIDES = {
    "𧒽岗" => "GF13",
    "庆盛" => "411",
    "机场北" => "330"
  }.freeze

  # Canonical stations with no usable operator service-time reference. Reviewed individually — an
  # unreviewed gap is an error, not a silent omission.
  #   机场南 — in the network, but the operator omits it from the line listing and its
  #            serviceTime response is empty, so there is no published first/last to link to.
  #   会展西 — Haizhu Tram; the metro serviceTime API rejects its stop, so it is another operator.
  REVIEWED_GAPS = {
    "机场南" => "operatorOmitsServiceTime",
    "会展西" => "haizhuTram"
  }.freeze

  # Bracket and separator forms differ between the operator's listing and OSM; normalise both
  # sides before matching and keep the operator's spelling as an alias whenever it differs.
  SEPARATORS = /[·・･、\s()（）\[\]【】\-—―]/

  module_function

  def fetch_line_station(url: LINE_STATION_URL)
    uri = URI(url)
    response = Net::HTTP.start(
      uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 15, read_timeout: 30
    ) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["User-Agent"] = "JustGo-DataImport/1.0"
      request.body = "{}"
      http.request(request)
    end
    unless response.code == "200"
      raise ImportError, "Guangzhou line-station returned HTTP #{response.code}"
    end

    JSON.parse(response.body.to_s.force_encoding("UTF-8").scrub)
  rescue JSON::ParserError => error
    raise ImportError, "Guangzhou line-station returned invalid JSON: #{error.message}"
  end

  def import(line_station:, network:)
    source_by_name, source_codes = parse_line_station(line_station)
    canonical_stations, canonical_lines = parse_network(network)

    used_codes = {}
    mappings = []
    gaps = []
    mapped_names = {}

    canonical_stations.each do |station|
      name = station.fetch("stationName")
      representative, source_name = resolve(name, source_by_name, source_codes)

      unless representative
        gaps << gap_record(station, canonical_lines)
        next
      end

      if used_codes.key?(representative)
        raise ImportError,
              "Guangzhou station reference #{representative} maps to multiple canonical stations"
      end
      used_codes[representative] = station.fetch("stationID")
      mapped_names[normalized(name)] = true

      mappings << {
        "stationID" => station.fetch("stationID"),
        "stationName" => name,
        "stationNameEn" => station.fetch("stationNameEn"),
        "aliases" => source_name == name ? [] : [source_name],
        "externalStationID" => representative
      }
    end

    source_only = source_codes.values
      .map { |entry| entry.fetch("name") }
      .reject { |source_name| mapped_names.key?(normalized(source_name)) }
      .uniq
      .sort

    {
      "schemaVersion" => 1,
      "verifiedAt" => VERIFIED_AT,
      "sourceIndexURL" => LINE_STATION_URL,
      "sourceIndexSHA256" => Digest::SHA256.hexdigest(JSON.generate(line_station)),
      "serviceTimeURL" => SERVICE_TIME_URL,
      "operatorURL" => OPERATOR_URL,
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

  # Returns [representative_show_code, source_display_name] for a canonical station name, or
  # [nil, nil] when nothing in the operator's listing covers it.
  def resolve(name, source_by_name, source_codes)
    if (override = NAME_OVERRIDES[name])
      entry = source_codes[override]
      unless entry
        raise ImportError, "reviewed override #{override} for #{name} is not in the operator listing"
      end
      return [override, entry.fetch("name")]
    end

    matches = source_by_name[normalized(name)]
    return [nil, nil] unless matches

    codes = matches.map { |match| match.fetch("code") }
    representative = codes.min_by { |code| code_sort_key(code) }
    source_name = matches.find { |match| match.fetch("code") == representative }.fetch("name")
    [representative, source_name]
  end

  # Numeric codes sort before alphanumeric ones, and numerically among themselves, so the
  # representative is a stable, human-obvious "lowest" reference ("101" before "GF18").
  def code_sort_key(code)
    code.match?(/\A\d+\z/) ? [0, code.to_i, code] : [1, 0, code]
  end

  def parse_line_station(payload)
    unless payload.is_a?(Hash) && payload["businessObject"].is_a?(Array)
      raise ImportError, "Guangzhou line-station contract is invalid"
    end

    source_codes = {}
    payload.fetch("businessObject").each do |line|
      next unless line.is_a?(Hash)

      Array(line["stations"]).each do |station|
        raise ImportError, "Guangzhou station entry is not an object" unless station.is_a?(Hash)

        code = non_empty_string(station["stationShowCode"], "station show code")
        name = non_empty_string(station["stationName"], "station name for #{code}")
        name_en = station["stationNameEn"].to_s.strip
        existing = source_codes[code]
        if existing && existing.fetch("name") != name
          raise ImportError, "show code #{code} names two stations: #{existing.fetch('name')} / #{name}"
        end
        source_codes[code] ||= {
          "code" => code,
          "name" => name,
          "nameEn" => name_en.empty? ? name : name_en
        }
      end
    end
    raise ImportError, "Guangzhou line-station listing is empty" if source_codes.empty?

    source_by_name = source_codes.values.each_with_object({}) do |entry, index|
      (index[normalized(entry.fetch("name"))] ||= []) << entry
    end
    [source_by_name, source_codes]
  end

  def parse_network(network)
    unless network.is_a?(Hash) && network["cityID"] == "4401" &&
           network["stations"].is_a?(Array) && network["lines"].is_a?(Array)
      raise ImportError, "canonical Guangzhou network contract is invalid"
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
    raise ImportError, "duplicate canonical Guangzhou station ID" unless ids.uniq.length == ids.length

    [stations, line_names]
  end

  def gap_record(station, _canonical_lines)
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
