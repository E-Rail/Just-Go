# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"

module OfficialTransitResourceImporter
  SYSTEM_INDEX_URL = "https://www.mtr.com.hk/en/customer/services/system_map.html"
  LIGHT_RAIL_INDEX_URL = "https://www.mtr.com.hk/en/customer/services/stmap_index.html"
  VERIFIED_AT = "2026-07-15"

  class ImportError < StandardError; end

  module_function

  def fetch(url)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "JustGo official-resource catalog importer"
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: true,
      open_timeout: 5,
      read_timeout: 15
    ) { |http| http.request(request) }
    raise ImportError, "#{url} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def import(system_html:, light_rail_html:, station_bindings_path:)
    bindings = JSON.parse(File.read(station_bindings_path))
    raise ImportError, "Hong Kong station bindings must use schema 1" unless bindings.fetch("schemaVersion") == 1

    stations = bindings.fetch("stations")
    raise ImportError, "expected 162 canonical Hong Kong stations, found #{stations.length}" unless stations.length == 162
    station_ids = stations.map { |station| station.fetch("stationID") }
    raise ImportError, "duplicate canonical Hong Kong station binding" unless station_ids.uniq.length == 162
    heavy_rail = bind_heavy_rail(parse_system_index(system_html), stations)
    light_rail = bind_light_rail(parse_light_rail_index(light_rail_html), stations)

    {
      "schemaVersion" => 1,
      "verifiedAt" => VERIFIED_AT,
      "sourcePages" => [SYSTEM_INDEX_URL, LIGHT_RAIL_INDEX_URL],
      "systemMap" => absolute_mtr_url(parse_system_index(system_html).fetch("systemMapPath")),
      "heavyRailStations" => heavy_rail,
      "lightRailMaps" => light_rail
    }
  end

  def parse_system_index(html)
    system_match = html.match(%r{href=["']([^"']*/archive/en/services/routemap\.pdf)["']}i)
    raise ImportError, "MTR system-map link is missing" unless system_match

    records = {}
    table_rows(html).each do |cells|
      next unless cells.length == 3

      location_paths = hrefs(cells[1])
      layout_paths = hrefs(cells[2])
      next unless location_paths.length == 1 && layout_paths.length == 1

      location_path = location_paths.first
      layout_path = layout_paths.first
      next unless location_path&.match?(%r{\A/archive/ch/services/maps/[a-z0-9]+\.pdf\z}i)
      next unless layout_path&.match?(%r{\A/archive/ch/services/layouts/[a-z0-9]+\.pdf\z}i)

      station_name = plain_text(cells[0])
      next if station_name.empty?

      code = File.basename(location_path, ".pdf").upcase
      layout_code = File.basename(layout_path, ".pdf").upcase
      raise ImportError, "#{station_name} map/layout code mismatch" unless code == layout_code

      record = {
        "stationName" => station_name,
        "stationCode" => code,
        "locationMapPath" => location_path,
        "stationLayoutPath" => layout_path
      }
      if records.key?(code) && records.fetch(code) != record
        raise ImportError, "conflicting duplicate heavy-rail mapping for #{code}"
      end
      records[code] = record
    end

    raise ImportError, "expected 98 heavy-rail stations, found #{records.length}" unless records.length == 98

    location_paths = records.values.map { |record| record.fetch("locationMapPath") }
    layout_paths = records.values.map { |record| record.fetch("stationLayoutPath") }
    raise ImportError, "duplicate heavy-rail location map" unless location_paths.uniq.length == 98
    raise ImportError, "duplicate heavy-rail station layout" unless layout_paths.uniq.length == 98

    {
      "systemMapPath" => system_match[1],
      "stations" => records.values.sort_by { |record| record.fetch("stationCode") }
    }
  end

  def parse_light_rail_index(html)
    maps = table_rows(html).each_with_object([]) do |cells, result|
      next unless cells.length == 2

      path = first_href(cells[0])
      path_match = path&.match(%r{\A/archive/en/services/lrt_(\d{2})\.pdf\z}i)
      next unless path_match

      map_number = path_match[1].to_i
      stops = cell_lines(cells[1])
      raise ImportError, "Light Rail map #{map_number} has no stops" if stops.empty?

      result << {
        "mapNumber" => map_number,
        "pdfPath" => path,
        "stops" => stops
      }
    end

    raise ImportError, "expected 14 Light Rail maps, found #{maps.length}" unless maps.length == 14
    raise ImportError, "duplicate Light Rail map number" unless maps.map { |map| map.fetch("mapNumber") }.uniq.length == 14
    raise ImportError, "duplicate Light Rail PDF" unless maps.map { |map| map.fetch("pdfPath") }.uniq.length == 14
    raise ImportError, "Light Rail maps must be numbered 1 through 14" unless maps.map { |map| map.fetch("mapNumber") }.sort == (1..14).to_a

    duplicate_stops = maps.flat_map { |map| map.fetch("stops") }
      .group_by { |stop| normalized_name(stop) }
      .select { |_name, values| values.length > 1 }
    raise ImportError, "duplicate Light Rail stops: #{duplicate_stops.values.flatten.join(', ')}" unless duplicate_stops.empty?

    maps.sort_by { |map| map.fetch("mapNumber") }
  end

  def bind_heavy_rail(parsed, stations)
    by_code = Hash.new { |hash, key| hash[key] = [] }
    stations.each do |station|
      station.fetch("liveArrivalReferences", []).each do |reference|
        next unless reference.fetch("mode") == "heavyRail"

        by_code[reference.fetch("stationCode").upcase] << station
      end
    end

    bound = parsed.fetch("stations").map do |record|
      matches = by_code.fetch(record.fetch("stationCode"), []).uniq
      raise ImportError, "unknown or ambiguous heavy-rail code #{record.fetch('stationCode')}" unless matches.length == 1

      station = matches.first
      unless station_names(station).include?(normalized_name(record.fetch("stationName")))
        raise ImportError, "#{record.fetch('stationName')} does not match #{record.fetch('stationCode')}"
      end

      {
        "stationID" => station.fetch("stationID"),
        "stationName" => station.fetch("stationName"),
        "stationNameEn" => station.fetch("stationNameEn"),
        "aliases" => station.fetch("aliases"),
        "stationCode" => record.fetch("stationCode"),
        "locationMapURL" => absolute_mtr_url(record.fetch("locationMapPath")),
        "stationLayoutURL" => absolute_mtr_url(record.fetch("stationLayoutPath"))
      }
    end.sort_by { |record| record.fetch("stationID") }

    expected_ids = stations.select do |station|
      station.fetch("liveArrivalReferences", []).any? { |reference| reference.fetch("mode") == "heavyRail" }
    end.map { |station| station.fetch("stationID") }.uniq.sort
    bound_ids = bound.map { |record| record.fetch("stationID") }
    raise ImportError, "heavy-rail source does not cover 98 distinct canonical stations" unless bound_ids.uniq.length == 98
    raise ImportError, "heavy-rail canonical coverage mismatch" unless bound_ids.sort == expected_ids

    bound
  end

  def bind_light_rail(parsed, stations)
    light_rail_stations = stations.select do |station|
      station.fetch("liveArrivalReferences", []).any? { |reference| reference.fetch("mode") == "lightRail" }
    end

    bound_maps = parsed.map do |map|
      bound_stops = map.fetch("stops").map do |source_name|
        matches = light_rail_stations.select { |station| station_names(station).include?(normalized_name(source_name)) }
        raise ImportError, "unknown or ambiguous Light Rail stop #{source_name}" unless matches.length == 1

        station = matches.first
        {
          "stationID" => station.fetch("stationID"),
          "stationName" => station.fetch("stationName"),
          "stationNameEn" => station.fetch("stationNameEn"),
          "aliases" => station.fetch("aliases"),
          "sourceName" => source_name
        }
      end

      {
        "mapNumber" => map.fetch("mapNumber"),
        "pdfURL" => absolute_mtr_url(map.fetch("pdfPath")),
        "stops" => bound_stops.sort_by { |stop| stop.fetch("stationID") }
      }
    end

    expected_ids = light_rail_stations.map { |station| station.fetch("stationID") }.uniq.sort
    bound_ids = bound_maps.flat_map { |map| map.fetch("stops") }.map { |stop| stop.fetch("stationID") }
    raise ImportError, "duplicate canonical Light Rail stop mapping" unless bound_ids.uniq.length == bound_ids.length
    raise ImportError, "Light Rail canonical coverage mismatch" unless bound_ids.sort == expected_ids

    bound_maps
  end

  def table_rows(html)
    html.scan(%r{<tr\b[^>]*>(.*?)</tr>}mi).map do |row_match|
      row_match.first.scan(%r{<td\b[^>]*>(.*?)</td>}mi).flatten
    end
  end

  def first_href(fragment)
    hrefs(fragment).first
  end

  def hrefs(fragment)
    fragment.scan(/href\s*=\s*["']([^"']+)["']/i)
      .flatten
      .map { |value| CGI.unescapeHTML(value).strip }
  end

  def cell_lines(fragment)
    CGI.unescapeHTML(fragment.gsub(%r{<br\s*/?>}i, "\n").gsub(%r{<[^>]+>}, " "))
      .split("\n")
      .map { |line| line.gsub(/\s+/, " ").strip }
      .reject(&:empty?)
  end

  def plain_text(fragment)
    CGI.unescapeHTML(fragment.gsub(%r{<[^>]+>}, " ")).gsub(/\s+/, " ").strip
  end

  def station_names(station)
    [station["stationName"], station["stationNameEn"], *station.fetch("aliases", [])]
      .compact
      .map { |name| normalized_name(name) }
      .uniq
  end

  def normalized_name(value)
    value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^\p{Alnum}]+/, "")
  end

  def absolute_mtr_url(path)
    URI.join("https://www.mtr.com.hk", path).to_s
  end
end
