# frozen_string_literal: true

require "json"
require "uri"
require_relative "official_transit_city_reviews"

module OfficialTransitResourceCatalogBuilder
  VERIFIED_AT = "2026-07-15"
  CATALOG_CITY_IDS = %w[
    1100 4401 3100 1200 5000 2101 3201 4201 5101 6101 1301 1401 4101
    4103 4110 5120 2102 2201 2301 1501 3202 3205 3203 3204 3701 3702
    3401 3402 3411 3301 3302 3306 3303 3307 3310 3501 3502 4301 4303
    4331 4403 4406 4419 4501 3601 5201 5301 6201 3206 6501 8100 8200
    4207 4418 7101 7102 7106 7104
  ].freeze
  RESOURCE_KINDS = %w[
    systemMap locationMap streetMap stationLayout serviceStatus journeyPlanner timetable
    fareInformation stationInformation accessibility stationFacilities customerService
    operatorInformation
  ].freeze
  RESOURCE_FORMATS = %w[webPage pdf image].freeze
  REVIEW_STATUSES = %w[verifiedResources noVerifiedOfficialResource].freeze
  STATION_INFORMATION_STATUSES = %w[
    exactPage officialContextOnly notOpenForPassengerService noCurrentPassengerService
  ].freeze
  REDIRECT_QUERY_KEYS = %w[
    continue destination redirect redirect_uri redirect_url return return_to target url uri
  ].freeze

  class BuildError < StandardError; end

  class Builder
    def initialize(root: File.expand_path("../..", __dir__))
      @root = File.expand_path(root)
    end

    def build(
      cities: reviewed_cities,
      beijing: JSON.parse(File.read(beijing_source_path)),
      hong_kong: JSON.parse(File.read(hong_kong_source_path))
    )
      validate_city_sources!(cities)

      built_cities = cities.map do |city|
        city = deep_copy(city)
        if city.fetch("cityID") == "1100"
          add_beijing_resources!(city, beijing)
        elsif city.fetch("cityID") == "8100"
          add_hong_kong_resources!(city, hong_kong)
        end
        city["stationResources"] ||= []
        city["resources"] ||= []
        city["coverage"] = coverage(city)
        city
      end.sort_by { |city| CATALOG_CITY_IDS.index(city.fetch("cityID")) }

      {
        "schemaVersion" => 1,
        "generatedAt" => "2026-07-17T00:00:00Z",
        "cities" => built_cities
      }
    end

    def reviewed_cities
      OfficialTransitCityReviews::CITY_REVIEWS.map do |city_id, name, name_en, name_traditional, source_resources, review_note|
        verified_at = city_id == "1100" ? "2026-07-17" : VERIFIED_AT
        resources = source_resources.map do |kind, title, target_url, provider, source_page_url|
          resource(
            kind: kind,
            title: title,
            target_url: target_url,
            source_page_url: source_page_url || target_url,
            provider: provider,
            scope: "city",
            format: "webPage",
            verified_at: verified_at
          )
        end
        domains = resources.flat_map do |item|
          [URI(item.fetch("targetURL")).host.downcase, URI(item.fetch("sourcePageURL")).host.downcase]
        end.uniq.sort
        {
          "cityID" => city_id,
          "name" => name,
          "nameEn" => name_en,
          "nameTraditional" => name_traditional,
          "reviewStatus" => resources.empty? ? "noVerifiedOfficialResource" : "verifiedResources",
          "verifiedAt" => verified_at,
          "reviewNote" => review_note,
          "officialDomains" => domains,
          "resources" => resources
        }.compact
      end
    end

    private

    def add_beijing_resources!(city, source)
      unless source.fetch("schemaVersion") == 1 &&
             source.fetch("verifiedAt") == city.fetch("verifiedAt") &&
             source.fetch("sourceIndexURL") == "https://www.bjsubway.com/api/guanwang/v2/lineStations" &&
             source.fetch("sourceDirectoryURL") == "https://www.bjsubway.com/station/" &&
             source.fetch("mappedStationCount") == source.fetch("stations").length &&
             source.fetch("stationPageCount") ==
               source.fetch("stations").length + source.fetch("legacyStationPages").length &&
             source.fetch("stationPageGapCount") ==
               source.fetch("canonicalStationCount") - source.fetch("stationPageCount")
        raise BuildError, "Beijing station-information source is invalid"
      end

      city.fetch("resources") << resource(
        kind: "stationInformation",
        title: "Beijing Subway station directory",
        target_url: source.fetch("sourceDirectoryURL"),
        source_page_url: source.fetch("sourceDirectoryURL"),
        provider: source.fetch("provider"),
        scope: "city",
        format: "webPage",
        verified_at: city.fetch("verifiedAt")
      )
      structured_stations = source.fetch("stations").map do |station|
        station_id = station.fetch("stationID")
        {
          "stationID" => station_id,
          "stationName" => station.fetch("stationName"),
          "stationNameEn" => station.fetch("stationNameEn"),
          "aliases" => station.fetch("aliases"),
          "stationInformationStatus" => "exactPage",
          "resources" => [
            resource(
              kind: "stationInformation",
              title: "#{station.fetch('stationNameEn')} Official Station Information",
              target_url: station.fetch("sourcePageURL"),
              source_page_url: source.fetch("sourceDirectoryURL"),
              provider: source.fetch("provider"),
              scope: "station",
              format: "webPage",
              station_id: station_id,
              verified_at: city.fetch("verifiedAt")
            )
          ]
        }
      end
      legacy_stations = source.fetch("legacyStationPages").map do |station|
        station_id = station.fetch("stationID")
        {
          "stationID" => station_id,
          "stationName" => station.fetch("stationName"),
          "stationNameEn" => station.fetch("stationNameEn"),
          "aliases" => station.fetch("aliases"),
          "stationInformationStatus" => "exactPage",
          "resources" => [
            resource(
              kind: "stationInformation",
              title: "#{station.fetch('stationNameEn')} Official Station Information",
              target_url: station.fetch("sourcePageURL"),
              source_page_url: station.fetch("sourcePageURL"),
              provider: source.fetch("provider"),
              scope: "station",
              format: "webPage",
              station_id: station_id,
              verified_at: city.fetch("verifiedAt")
            )
          ]
        }
      end
      legacy_ids = legacy_stations.map { |station| station.fetch("stationID") }
      reviewed_gap_stations = source.fetch("canonicalCoverageGaps").each_with_object([]) do |station, records|
        next if legacy_ids.include?(station.fetch("stationID"))

        station_id = station.fetch("stationID")
        status = station.fetch("informationStatus")
        unless STATION_INFORMATION_STATUSES.include?(status)
          raise BuildError, "Beijing station #{station.fetch('stationName')} has an invalid review status"
        end
        records << {
          "stationID" => station_id,
          "stationName" => station.fetch("stationName"),
          "stationNameEn" => station.fetch("stationNameEn"),
          "aliases" => [],
          "stationInformationStatus" => status,
          "resources" => station.fetch("resources").map do |item|
            resource(
              kind: item.fetch("kind"),
              title: item.fetch("title"),
              target_url: item.fetch("targetURL"),
              source_page_url: item.fetch("sourcePageURL"),
              provider: item.fetch("provider"),
              scope: "station",
              format: item.fetch("format"),
              station_id: station_id,
              verified_at: city.fetch("verifiedAt")
            )
          end
        }
      end
      city["stationResources"] = (structured_stations + legacy_stations + reviewed_gap_stations)
        .sort_by { |station| station.fetch("stationID") }
      city["resources"] = city.fetch("resources")
        .sort_by { |item| [RESOURCE_KINDS.index(item.fetch("kind")), item.fetch("targetURL")] }
      city["officialDomains"] = (
        city.fetch("officialDomains") +
        (city.fetch("resources") + city.fetch("stationResources").flat_map { |station| station.fetch("resources") })
          .flat_map { |item| [URI(item.fetch("targetURL")).host, URI(item.fetch("sourcePageURL")).host] }
          .compact
          .map(&:downcase)
      ).uniq.sort
    end

    def add_hong_kong_resources!(city, source)
      source_pages = source.fetch("sourcePages")
      system_source = source_pages.fetch(0)
      street_source = source_pages.fetch(1)
      city.fetch("resources") << resource(
        kind: "systemMap",
        title: "MTR System Map",
        target_url: source.fetch("systemMap"),
        source_page_url: system_source,
        provider: "MTR Corporation Limited",
        scope: "city",
        format: "pdf",
        verified_at: city.fetch("verifiedAt")
      )

      stations = {}
      source.fetch("heavyRailStations").each do |station|
        station_record = station_record(stations, station)
        station_record.fetch("resources") << resource(
          kind: "locationMap",
          title: "#{station.fetch('stationNameEn')} Location Map",
          target_url: station.fetch("locationMapURL"),
          source_page_url: system_source,
          provider: "MTR Corporation Limited",
          scope: "station",
          format: "pdf",
          station_id: station.fetch("stationID"),
          verified_at: city.fetch("verifiedAt")
        )
        station_record.fetch("resources") << resource(
          kind: "stationLayout",
          title: "#{station.fetch('stationNameEn')} Station Layout",
          target_url: station.fetch("stationLayoutURL"),
          source_page_url: system_source,
          provider: "MTR Corporation Limited",
          scope: "station",
          format: "pdf",
          station_id: station.fetch("stationID"),
          verified_at: city.fetch("verifiedAt")
        )
      end

      source.fetch("lightRailMaps").each do |map|
        map.fetch("stops").each do |station|
          station_record = station_record(stations, station)
          station_record.fetch("resources") << resource(
            kind: "streetMap",
            title: "#{station.fetch('stationNameEn')} Street Map",
            target_url: map.fetch("pdfURL"),
            source_page_url: street_source,
            provider: "MTR Corporation Limited",
            scope: "station",
            format: "pdf",
            station_id: station.fetch("stationID"),
            verified_at: city.fetch("verifiedAt")
          )
        end
      end

      city["stationResources"] = stations.values.sort_by { |station| station.fetch("stationID") }
      city["resources"] = city.fetch("resources").sort_by { |item| [RESOURCE_KINDS.index(item.fetch("kind")), item.fetch("targetURL")] }
    end

    def station_record(stations, source)
      stations[source.fetch("stationID")] ||= {
        "stationID" => source.fetch("stationID"),
        "stationName" => source.fetch("stationName"),
        "stationNameEn" => source.fetch("stationNameEn"),
        "aliases" => source.fetch("aliases"),
        "resources" => []
      }
    end

    def resource(
      kind:,
      title:,
      target_url:,
      source_page_url:,
      provider:,
      scope:,
      format:,
      station_id: nil,
      verified_at: VERIFIED_AT
    )
      value = {
        "kind" => kind,
        "title" => title,
        "targetURL" => target_url,
        "sourcePageURL" => source_page_url,
        "provider" => provider,
        "scope" => scope,
        "format" => format,
        "verifiedAt" => verified_at
      }
      value["stationID"] = station_id if station_id
      value
    end

    def coverage(city)
      resources = city.fetch("resources") + city.fetch("stationResources").flat_map { |station| station.fetch("resources") }
      counts = RESOURCE_KINDS.to_h { |kind| [kind, resources.count { |resource| resource.fetch("kind") == kind }] }
      {
        "totalLinks" => resources.length,
        "maps" => %w[systemMap locationMap streetMap stationLayout].sum { |kind| counts.fetch(kind) },
        "travel" => %w[
          serviceStatus journeyPlanner timetable fareInformation stationInformation
        ].sum { |kind| counts.fetch(kind) },
        "accessibility" => %w[accessibility stationFacilities].sum { |kind| counts.fetch(kind) },
        "help" => %w[customerService operatorInformation].sum { |kind| counts.fetch(kind) }
      }
    end

    def validate_city_sources!(cities)
      ids = cities.map { |city| city.fetch("cityID") }
      raise BuildError, "city source must contain exactly 58 reviewed cities" unless ids == CATALOG_CITY_IDS
      raise BuildError, "duplicate city source record" unless ids.uniq.length == ids.length

      cities.each do |city|
        status = city.fetch("reviewStatus")
        raise BuildError, "#{city.fetch('cityID')} has unknown review status" unless REVIEW_STATUSES.include?(status)
        unless city.fetch("verifiedAt").match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise BuildError, "#{city.fetch('cityID')} has an invalid verification date"
        end
        %w[name nameEn nameTraditional].each do |key|
          raise BuildError, "#{city.fetch('cityID')} has blank #{key}" if city.fetch(key).strip.empty?
        end
        domains = city.fetch("officialDomains")
        raise BuildError, "#{city.fetch('cityID')} official domains must be unique" unless domains == domains.uniq.sort
        resources = city.fetch("resources")
        if status == "noVerifiedOfficialResource"
          raise BuildError, "#{city.fetch('cityID')} no-resource result contains links" unless resources.empty?
          note = city.fetch("reviewNote")
          raise BuildError, "#{city.fetch('cityID')} no-resource result needs a note" if note.strip.empty?
        else
          raise BuildError, "#{city.fetch('cityID')} verified result has no links" if resources.empty? && city.fetch("cityID") != "8100"
        end
        resources.each { |item| validate_seed_resource!(city, item) }
      end
    end

    def validate_seed_resource!(city, resource)
      expected_keys = %w[format kind provider scope sourcePageURL targetURL title verifiedAt]
      raise BuildError, "#{city.fetch('cityID')} malformed resource keys" unless resource.keys.sort == expected_keys
      raise BuildError, "#{city.fetch('cityID')} unknown kind" unless RESOURCE_KINDS.include?(resource.fetch("kind"))
      raise BuildError, "#{city.fetch('cityID')} unknown format" unless RESOURCE_FORMATS.include?(resource.fetch("format"))
      raise BuildError, "#{city.fetch('cityID')} seed resources must be city-scoped" unless resource.fetch("scope") == "city"
      unless resource.fetch("verifiedAt") == city.fetch("verifiedAt")
        raise BuildError, "#{city.fetch('cityID')} resource verification date mismatch"
      end

      [resource.fetch("targetURL"), resource.fetch("sourcePageURL")].each do |value|
        url = URI(value)
        unless url.scheme == "https" && url.userinfo.nil? && city.fetch("officialDomains").include?(url.host&.downcase)
          raise BuildError, "#{city.fetch('cityID')} undeclared or unsafe URL #{value}"
        end
        if value.match?(/[{}]|%7b|%7d|%s/i)
          raise BuildError, "#{city.fetch('cityID')} URL template is forbidden"
        end
        query_keys = URI.decode_www_form(url.query.to_s).map { |key, _value| key.downcase }
        if !(query_keys & REDIRECT_QUERY_KEYS).empty?
          raise BuildError, "#{city.fetch('cityID')} arbitrary redirect URL is forbidden"
        end
      rescue URI::InvalidURIError
        raise BuildError, "#{city.fetch('cityID')} invalid URL #{value}"
      end
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end

    def hong_kong_source_path
      File.join(@root, "DataPacks", "sources", "official-resources", "hong_kong_index.json")
    end

    def beijing_source_path
      File.join(
        @root,
        "DataPacks",
        "sources",
        "official-resources",
        "beijing_station_information.json"
      )
    end
  end
end
