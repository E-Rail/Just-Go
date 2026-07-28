# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "gcj02"

# Imports station entrances (`railway=subway_entrance`) from OpenStreetMap and binds each one to
# the canonical station it serves.
#
# Unlike every operator feed in this repo, OSM is ODbL: entrances can be *bundled* and shipped
# offline rather than fetched on the rider's device, so this is the only source that can give a
# city a working exit list and exit map with no network at all.
#
# Two things this module exists to get right:
#
#   * Coordinate frame. OSM publishes WGS-84; the app draws everything in GCJ-02 (see gcj02.rb).
#     Matching without converting puts every entrance ~600 m from its own station, which silently
#     produces an empty import rather than a wrong one — so the conversion happens before any
#     distance is measured, and `MAX_MATCH_METRES` is tight enough that a regression shows up as
#     a collapse in matched counts.
#   * Ambiguity. An entrance between two stations belongs to neither by guesswork: it is bound to
#     the nearest station only when that station is unambiguously closer than the runner-up.
module OSMStationEntranceImporter
  ImportError = Class.new(StandardError)

  OVERPASS_URLS = [
    URI("https://overpass-api.de/api/interpreter"),
    URI("https://overpass.kumi.systems/api/interpreter")
  ].freeze
  ATTRIBUTION = "© OpenStreetMap contributors"
  LICENSE_URL = "https://www.openstreetmap.org/copyright"

  # An entrance further than this from its station is not that station's entrance. Beijing's
  # converted distribution is median 95 m / p90 180 m, so 300 m keeps the long tail of large
  # interchanges while still rejecting a neighbouring station's exits.
  MAX_MATCH_METRES = 300.0
  # A tie this close cannot be resolved by distance alone, so the entrance is dropped rather than
  # assigned to a coin-flip winner.
  AMBIGUITY_RATIO = 1.25

  EARTH_RADIUS_METRES = 6_371_000.0

  module_function

  def overpass_query(bbox)
    south, west, north, east = bbox
    "[out:json][timeout:300];" \
      "node[\"railway\"=\"subway_entrance\"](#{south},#{west},#{north},#{east});" \
      "out tags center;"
  end

  # Overpass is a shared, free service: a burst of city-sized queries earns 504s and dropped
  # connections rather than a rate-limit header. Back off and retry instead of failing the whole
  # run on one busy moment, and try each mirror in turn on every attempt.
  RETRY_DELAYS = [10, 30, 60, 120].freeze

  def fetch(bbox, sleeper: method(:sleep), logger: nil)
    body = "data=#{URI.encode_www_form_component(overpass_query(bbox))}"
    last_error = nil

    RETRY_DELAYS.each_with_index do |delay, attempt|
      OVERPASS_URLS.each do |url|
        begin
          response = Net::HTTP.start(
            url.host, url.port, use_ssl: url.scheme == "https",
            open_timeout: 30, read_timeout: 360
          ) do |http|
            request = Net::HTTP::Post.new(url.request_uri)
            request["Content-Type"] = "application/x-www-form-urlencoded"
            request["User-Agent"] = "JustGo-DataImport/1.0"
            request.body = body
            http.request(request)
          end
          if response.code == "200"
            return JSON.parse(response.body.to_s.force_encoding("UTF-8").scrub)
          end

          last_error = "HTTP #{response.code} from #{url.host}"
        rescue StandardError => error
          last_error = "#{error.class} from #{url.host}: #{error.message}"
        end
      end

      break if attempt == RETRY_DELAYS.length - 1

      logger&.call("  #{last_error}; retrying in #{delay}s")
      sleeper.call(delay)
    end

    raise ImportError, "Overpass entrance query failed: #{last_error}"
  end

  # Reduces the Overpass response to the fields the app uses. This is what gets committed: small,
  # diffable, and auditable against the licence, unlike the multi-megabyte raw response.
  def normalize(payload)
    unless payload.is_a?(Hash) && payload["elements"].is_a?(Array)
      raise ImportError, "Overpass entrance payload is invalid"
    end

    entrances = payload.fetch("elements").map { |element|
      next unless element.is_a?(Hash) && element["type"] == "node"

      latitude = element["lat"]
      longitude = element["lon"]
      next unless latitude.is_a?(Numeric) && longitude.is_a?(Numeric)

      tags = element["tags"].is_a?(Hash) ? element["tags"] : {}
      next unless tags["railway"] == "subway_entrance"

      record = {
        "osmNodeID" => element.fetch("id").to_s,
        "latitude" => latitude.round(7),
        "longitude" => longitude.round(7)
      }
      %w[ref name name:en wheelchair].each do |key|
        value = tags[key].to_s.strip
        record[key == "name:en" ? "nameEn" : key] = value unless value.empty?
      end
      record
    }.compact
    entrances.sort_by { |entrance| entrance.fetch("osmNodeID").to_i }
  end

  # Returns [bindings, stats]. `bindings` is station ID -> the entrances that station owns, each
  # already converted into the app's coordinate frame.
  def bind(entrances:, network:)
    stations = parse_network(network)
    bindings = Hash.new { |hash, key| hash[key] = [] }
    unmatched = 0
    ambiguous = 0

    entrances.each do |entrance|
      latitude, longitude = GCJ02.from_wgs84(
        entrance.fetch("latitude"),
        entrance.fetch("longitude")
      )
      ranked = stations
        .map { |station| [distance_metres(latitude, longitude, station), station] }
        .sort_by(&:first)
      nearest_distance, nearest = ranked.first
      if nearest.nil? || nearest_distance > MAX_MATCH_METRES
        unmatched += 1
        next
      end
      runner_up = ranked[1]&.first
      if runner_up && nearest_distance.positive? && runner_up < nearest_distance * AMBIGUITY_RATIO
        ambiguous += 1
        next
      end

      bindings[nearest.fetch("stationID")] << entrance.merge(
        "latitude" => latitude.round(7),
        "longitude" => longitude.round(7)
      )
    end

    bindings.each_value do |list|
      list.sort_by! { |entrance| [entrance["ref"].to_s, entrance.fetch("osmNodeID").to_i] }
    end

    stats = {
      "entranceCount" => entrances.length,
      "boundCount" => bindings.values.sum(&:length),
      "unmatchedCount" => unmatched,
      "ambiguousCount" => ambiguous,
      "stationsWithEntrances" => bindings.length,
      "networkStationCount" => stations.length
    }
    [bindings.sort.to_h, stats]
  end

  def document(city_id:, entrances:, network:)
    bindings, stats = bind(entrances: entrances, network: network)
    {
      "schemaVersion" => 1,
      "cityID" => city_id,
      "source" => "OpenStreetMap",
      "sourceQuery" => "node[railway=subway_entrance]",
      "attribution" => ATTRIBUTION,
      "licenseURL" => LICENSE_URL,
      "coordinateSystem" => "gcj02",
      "maxMatchMetres" => MAX_MATCH_METRES,
      "stats" => stats,
      "stations" => bindings
    }
  end

  def parse_network(network)
    unless network.is_a?(Hash) && network["stations"].is_a?(Array)
      raise ImportError, "canonical network contract is invalid"
    end

    network.fetch("stations").map do |station|
      latitude = station["latitude"]
      longitude = station["longitude"]
      unless latitude.is_a?(Numeric) && longitude.is_a?(Numeric)
        raise ImportError, "station #{station["id"]} has no coordinate"
      end

      { "stationID" => station.fetch("id"), "latitude" => latitude, "longitude" => longitude }
    end
  end

  def distance_metres(latitude, longitude, station)
    lat1 = latitude * Math::PI / 180.0
    lat2 = station.fetch("latitude") * Math::PI / 180.0
    delta_lat = lat2 - lat1
    delta_lon = (station.fetch("longitude") - longitude) * Math::PI / 180.0
    a = (Math.sin(delta_lat / 2)**2) +
        (Math.cos(lat1) * Math.cos(lat2) * (Math.sin(delta_lon / 2)**2))
    2 * EARTH_RADIUS_METRES * Math.asin(Math.sqrt(a))
  end
end
