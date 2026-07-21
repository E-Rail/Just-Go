# frozen_string_literal: true

require "cgi"
require "csv"
require "digest"
require "fileutils"
require "json"
require_relative "gcj02"

module OSSCityPackPipeline
  GENERATED_AT = "2026-07-15T00:00:00Z"
  VERSION = "oss-safe-v2-20260715"
  EMPTY_SHA256 = Digest::SHA256.hexdigest("")

  DataLicenseMetadata = Struct.new(
    :rights_id,
    :dataset_name,
    :terms_url,
    :attribution,
    :snapshot_date,
    :redistribution_evidence_url,
    :redistribution_evidence,
    keyword_init: true
  ) do
    def to_h
      {
        "rightsID" => rights_id,
        "datasetName" => dataset_name,
        "termsURL" => terms_url,
        "attribution" => attribution,
        "snapshotDate" => snapshot_date,
        "redistributionEvidenceURL" => redistribution_evidence_url,
        "redistributionEvidence" => redistribution_evidence
      }
    end
  end

  DATA_GOV_HK_LICENSE = DataLicenseMetadata.new(
    rights_id: "data-gov-hk-mtr",
    dataset_name: "MTR routes, stations, accessibility, and real-time MTR and Light Rail arrivals",
    terms_url: "https://data.gov.hk/en/terms-and-conditions",
    attribution: "MTR Corporation Limited and DATA.GOV.HK",
    snapshot_date: "2026-07-15",
    redistribution_evidence_url: "https://data.gov.hk/en/terms-and-conditions",
    redistribution_evidence: "Official DATA.GOV.HK Terms of Use v1.2 reviewed for reuse, redistribution, attribution, and source-identification conditions."
  ).freeze

  REALTIME_APIS = [
    {
      "mode" => "heavyRail",
      "endpointURL" => "https://rt.data.gov.hk/v1/transport/mtr/getSchedule.php",
      "datasetLandingPageURL" => "https://data.gov.hk/en-data/dataset/mtr-data2-nexttrain-data",
      "dataDictionaryURL" => "https://opendata.mtr.com.hk/doc/Next_Train_DataDictionary_v1.7.pdf",
      "rightsID" => "data-gov-hk-mtr",
      "attribution" => "MTR Corporation Limited and DATA.GOV.HK"
    },
    {
      "mode" => "lightRail",
      "endpointURL" => "https://rt.data.gov.hk/v1/transport/mtr/lrt/getSchedule",
      "datasetLandingPageURL" => "https://data.gov.hk/en-data/dataset/mtr-lrnt_data-light-rail-nexttrain-data",
      "dataDictionaryURL" => "https://opendata.mtr.com.hk/doc/LR_Next_Train_DataDictionary_v1.1.pdf",
      "rightsID" => "data-gov-hk-mtr",
      "attribution" => "MTR Corporation Limited and DATA.GOV.HK"
    }
  ].freeze

  RACECOURSE_REFERENCE = {
    "stationCode" => "RAC",
    "stationNumber" => "70",
    "lineCode" => "EAL",
    "canonicalStationID" => "5100239bb9315f24",
    "stationName" => "馬場",
    "stationNameEn" => "Racecourse",
    "evidenceURL" => "https://opendata.mtr.com.hk/doc/Next_Train_DataDictionary_v1.7.pdf"
  }.freeze

  CATALOG_CITY_IDS = %w[
    1100 4401 3100 1200 5000 2101 3201 4201 5101 6101 1301 1401 4101
    4103 4110 5120 2102 2201 2301 1501 3202 3205 3203 3204 3701 3702
    3401 3402 3411 3301 3302 3306 3303 3307 3310 3501 3502 4301 4303
    4331 4403 4406 4419 4501 3601 5201 5301 6201 3206 6501 8100 8200
    4207 4418 7101 7102 7106 7104
  ].freeze

  SOURCE_FILES = {
    "mtr_lines_and_stations.csv" => {
      snapshot: "justgo-mtr-lines.csv",
      source_url: "https://opendata.mtr.com.hk/data/mtr_lines_and_stations.csv",
      resource_url: "https://data.gov.hk/en-data/dataset/mtr-data-routes-fares-barrier-free-facilities"
    },
    "light_rail_routes_and_stops.csv" => {
      snapshot: "justgo-lrt-routes.csv",
      source_url: "https://opendata.mtr.com.hk/data/light_rail_routes_and_stops.csv",
      resource_url: "https://data.gov.hk/en-data/dataset/mtr-data-routes-fares-barrier-free-facilities"
    },
    "barrier_free_facilities.csv" => {
      snapshot: "justgo-barrier.csv",
      source_url: "https://opendata.mtr.com.hk/data/barrier_free_facilities.csv",
      resource_url: "https://data.gov.hk/en-data/dataset/mtr-data-routes-fares-barrier-free-facilities"
    },
    "barrier_free_facility_category.csv" => {
      snapshot: "justgo-barrier-categories.csv",
      source_url: "https://opendata.mtr.com.hk/data/barrier_free_facility_category.csv",
      resource_url: "https://data.gov.hk/en-data/dataset/mtr-data-routes-fares-barrier-free-facilities"
    }
  }.freeze

  BEIJING_CAPABILITIES = {
    "accessibility" => "source_pending",
    "schedules" => "source_pending",
    "liveArrivals" => "source_pending",
    "stationMaps" => "external_only",
    "licensedMedia" => "metadata_only",
    "verifiedTransferContexts" => "source_pending"
  }.freeze

  HONG_KONG_CAPABILITIES = {
    "accessibility" => "official_static",
    "schedules" => "source_pending",
    "liveArrivals" => "official_live",
    "stationMaps" => "external_only",
    "licensedMedia" => "metadata_only",
    "verifiedTransferContexts" => "source_pending"
  }.freeze

  # data.taipei publishes exits for the Taipei Metro proper but not for the New Taipei light-rail
  # and branch lines that share the same rider-facing network, so accessibility coverage is
  # partial by construction rather than pending.
  TAIPEI_CAPABILITIES = {
    "accessibility" => "partial_static",
    "schedules" => "source_pending",
    "liveArrivals" => "source_pending",
    "stationMaps" => "source_pending",
    "licensedMedia" => "source_pending",
    "verifiedTransferContexts" => "source_pending"
  }.freeze

  TAIPEI_SOURCE_FILES = %w[station_exits.csv stations.csv].freeze

  # "頂埔站出口1" → 頂埔 / 1. Taipei Main Station's exits are lettered without the 站出口 form.
  TAIPEI_EXIT_PATTERN = /\A(?<station>.+?)站(?:出入口|出口)(?<label>.*)\z/
  TAIPEI_MAIN_STATION = "台北車站"

  PENDING_CAPABILITIES = {
    "accessibility" => "source_pending",
    "schedules" => "source_pending",
    "liveArrivals" => "source_pending",
    "stationMaps" => "source_pending",
    "licensedMedia" => "source_pending",
    "verifiedTransferContexts" => "source_pending"
  }.freeze

  MACAU_EXTERNAL_RESOURCES = [
    {
      "kind" => "operatorInformation",
      "title" => "Official Macao Light Rapid Transit website",
      "landingPageURL" => "https://www.mlm.com.mo/en/",
      "provider" => "Macao Light Rapid Transit Corporation, Limited"
    }
  ].freeze

  MEDIA = {
    "jianguomen" => {
      "kind" => "stationPhoto",
      "title" => "Beijing Subway Jianguomen Station",
      "relativePath" => "LicensedMedia/beijing-jianguomen.jpg",
      "mimeType" => "image/jpeg",
      "sizeBytes" => 470_435,
      "sha256" => "54f8ab6ecab018924e43fb244b5d2d940a100a4680caa799e8e807a721adf750",
      "sourcePageURL" => "https://commons.wikimedia.org/wiki/File:Beijing_Subway_Jianguomen_Station_01.jpg",
      "creator" => "Ian Holton",
      "licenseSPDX" => "CC-BY-2.0",
      "licenseURL" => "https://creativecommons.org/licenses/by/2.0/",
      "attribution" => "Beijing Subway Jianguomen Station 01.jpg by Ian Holton, licensed CC BY 2.0.",
      "modifications" => "Auto-oriented, resized to a 2400-pixel maximum edge, converted to sRGB, re-encoded as JPEG, and stripped of metadata; no visual content edits."
    },
    "central" => {
      "kind" => "stationPhoto",
      "title" => "Central station in Hong Kong",
      "relativePath" => "LicensedMedia/hong-kong-central.jpg",
      "mimeType" => "image/jpeg",
      "sizeBytes" => 955_201,
      "sha256" => "7ef38511d29cee0872787d5ab154bafce6a0089af3bc48508999244ff0840370",
      "sourcePageURL" => "https://commons.wikimedia.org/wiki/File:Central_station_in_Hong_Kong.jpg",
      "creator" => "Qqhhss",
      "licenseSPDX" => "CC0-1.0",
      "licenseURL" => "https://creativecommons.org/publicdomain/zero/1.0/",
      "attribution" => "Central station in Hong Kong.jpg by Qqhhss, dedicated under CC0 1.0.",
      "modifications" => "Auto-oriented, resized to a 2400-pixel maximum edge, converted to sRGB, re-encoded as JPEG, and stripped of metadata; no visual content edits."
    }
  }.freeze

  class BuildError < StandardError; end

  class Builder
    attr_reader :root, :snapshot_dir

    def initialize(root: File.expand_path("../..", __dir__), snapshot_dir: "/private/tmp")
      @root = File.expand_path(root)
      @snapshot_dir = File.expand_path(snapshot_dir)
    end

    def run(refresh_sources: false)
      refuse_legacy_pack_tree!
      seed_sources!(refresh: refresh_sources)
      write_json(source_metadata_path, source_metadata)
      File.binwrite(third_party_notices_path, third_party_notices)
      write_json(rights_inventory_path, rights_inventory)

      packs = {
        "1100" => build_beijing_pack,
        "8100" => build_hong_kong_pack,
        "7101" => build_taipei_pack
      }
      packs.each { |city_id, pack| write_json(pack_path(city_id), pack) }
      write_json(manifest_path, build_manifest(packs))

      {
        city_count: CATALOG_CITY_IDS.length,
        bundled_city_count: packs.length,
        beijing_station_count: packs.fetch("1100").fetch("stations").length,
        hong_kong_station_count: packs.fetch("8100").fetch("stations").length,
        hong_kong_accessibility_source_groups: barrier_rows.map { |row| row["Station_No"] }.compact.uniq.length
      }
    end

    def build_beijing_pack
      network = load_network("1100")
      stations = network.fetch("stations").sort_by { |station| station.fetch("id") }.map do |station|
        media = station["nameEn"] == "Jianguomen" ? [deep_copy(MEDIA.fetch("jianguomen"))] : []
        base_station(station).merge(
          "externalResources" => [
            external_resource(
              "operatorInformation",
              "Official Beijing MTR station-information landing page",
              "https://www.mtr.bj.cn/service/line/",
              "Beijing MTR"
            ),
            external_resource(
              "operatorInformation",
              "Official Beijing Subway station-information landing page",
              "https://www.bjsubway.com/station/xltcx/",
              "Beijing Subway"
            )
          ],
          "licensedMedia" => media
        )
      end

      coverage = coverage_for(network.fetch("stations").length, stations)
      {
        "schemaVersion" => 2,
        "cityID" => "1100",
        "version" => VERSION,
        "generatedAt" => GENERATED_AT,
        "rightsIDs" => %w[osm-metro-networks beijing-official-landing-links media-jianguomen-ian-holton].sort,
        "capabilities" => deep_copy(BEIJING_CAPABILITIES),
        "coverage" => coverage,
        "stations" => stations
      }
    end

    def build_hong_kong_pack
      network = load_network("8100")
      canonical_index = canonical_station_index(network.fetch("stations"))
      line_index = network.fetch("lines").to_h do |line|
        [line.fetch("routeReference").downcase, line]
      end
      records = {}

      heavy_groups.each do |station_code, rows|
        source = rows.first
        canonical = match_canonical!(canonical_index, source["Chinese Name"], source["English Name"])
        record = records[canonical.fetch("id")] ||= base_station(canonical)
        add_source_aliases(record, canonical, source["Chinese Name"], source["English Name"])

        station_numbers = rows.map { |row| row["Station ID"] }.compact.uniq
        source_barriers = barrier_rows.select { |row| station_numbers.include?(row["Station_No"]) }
        raise BuildError, "no accessibility rows for heavy-rail station #{station_code}" if source_barriers.empty?

        record["accessibility"] = accessibility_record(source_barriers)
        record["stationFacilities"] = facility_records(canonical.fetch("id"), source_barriers)
        record["externalResources"] << external_resource(
          "stationLayout",
          "Official MTR station-layout landing page",
          "https://www.mtr.com.hk/en/customer/services/system_map.html",
          "MTR Corporation Limited"
        )
        record["liveArrivalReferences"].concat(
          rows.map { |row| row["Line Code"] }.compact.uniq.sort.map do |line_code|
            live_reference("heavyRail", line_code, station_code, line_index)
          end
        )
      end

      racecourse = network.fetch("stations").find do |station|
        station.fetch("id") == RACECOURSE_REFERENCE.fetch("canonicalStationID")
      end
      unless racecourse && racecourse["name"] == RACECOURSE_REFERENCE.fetch("stationName") &&
          racecourse["nameEn"] == RACECOURSE_REFERENCE.fetch("stationNameEn")
        raise BuildError, "Racecourse canonical station reference is inconsistent"
      end
      racecourse_barriers = barrier_rows.select do |row|
        row["Station_No"] == RACECOURSE_REFERENCE.fetch("stationNumber")
      end
      raise BuildError, "Racecourse accessibility group is missing" if racecourse_barriers.empty?
      racecourse_record = records[racecourse.fetch("id")] ||= base_station(racecourse)
      racecourse_record["accessibility"] = accessibility_record(racecourse_barriers)
      racecourse_record["stationFacilities"] = facility_records(racecourse.fetch("id"), racecourse_barriers)
      racecourse_record["externalResources"] << external_resource(
        "stationLayout",
        "Official MTR station-layout landing page",
        "https://www.mtr.com.hk/en/customer/services/system_map.html",
        "MTR Corporation Limited"
      )
      racecourse_record["liveArrivalReferences"] << live_reference(
        "heavyRail",
        RACECOURSE_REFERENCE.fetch("lineCode"),
        RACECOURSE_REFERENCE.fetch("stationCode"),
        line_index
      )

      light_rail_groups.each do |_stop_code, rows|
        source = rows.first
        canonical = if source["English Name"] == "Hoi Wong Road"
          match_canonical!(canonical_index, "屯門泳池", "Tuen Mun Swimming Pool")
        else
          match_canonical!(canonical_index, source["Chinese Name"], source["English Name"])
        end
        record = records[canonical.fetch("id")] ||= base_station(canonical)
        add_source_aliases(record, canonical, source["Chinese Name"], source["English Name"])
        if source["English Name"] == "Hoi Wong Road"
          record["aliases"].delete(source["Chinese Name"])
          record["aliases"].delete(source["English Name"])
          record["aliases"].concat([canonical["name"], canonical["nameEn"]].compact)
          record["stationName"] = source.fetch("Chinese Name")
          record["stationNameEn"] = source.fetch("English Name")
        end

        stop_id = source.fetch("Stop ID")
        record["liveArrivalReferences"].concat(
          rows.map { |row| row["Line Code"] }.compact.uniq.sort.map do |line_code|
            live_reference("lightRail", line_code, stop_id, line_index, route_reference: line_code)
          end
        )
      end

      central = records.values.find { |record| record["stationNameEn"] == "Central" }
      raise BuildError, "Central did not match the canonical network" unless central

      central["licensedMedia"] << deep_copy(MEDIA.fetch("central"))
      stations = records.values.each { |record| normalize_station_arrays!(record) }
        .sort_by { |record| record.fetch("stationID") }
      if stations.length != 162
        raise BuildError, "Hong Kong matched #{stations.length} canonical stations; expected 162"
      end

      unmatched = network.fetch("stations").reject do |station|
        records.key?(station.fetch("id"))
      end
      unless unmatched.empty?
        raise BuildError, "unexpected Hong Kong canonical gaps: #{unmatched.map { |station| station["nameEn"] }.inspect}"
      end

      coverage = coverage_for(network.fetch("stations").length, stations)
      {
        "schemaVersion" => 2,
        "cityID" => "8100",
        "version" => VERSION,
        "generatedAt" => GENERATED_AT,
        "rightsIDs" => %w[osm-metro-networks data-gov-hk-mtr media-central-qqhhss].sort,
        "capabilities" => deep_copy(HONG_KONG_CAPABILITIES),
        "coverage" => coverage,
        "destinationNames" => destination_names,
        "stations" => stations
      }
    end

    # Taipei's pack carries station exits: name, position and whether the exit is the barrier-free
    # one. The app already renders these (StationDetailView, TransferStationSheet) and had no
    # source for any city until now. Only facts present in the open data are emitted — in
    # particular an accessible exit is recorded as an accessible entrance and nothing is inferred
    # about lifts or ramps, which the dataset does not state.
    def build_taipei_pack
      network = load_network("7101")
      canonical_index = canonical_station_index(network.fetch("stations"))
      records = {}

      taipei_exit_rows.each do |row|
        source_name = row.fetch("出入口名稱").to_s.strip
        station_name, label = split_taipei_exit_name(source_name)
        candidates = canonical_index[normalize_name(station_name)]
        if candidates.length != 1
          raise BuildError,
            "Taipei exit #{source_name.inspect} matched #{candidates.length} canonical stations"
        end
        canonical = candidates.first
        record = records[canonical.fetch("id")] ||= base_station(canonical).merge(
          "stationAccessPoints" => []
        )

        latitude = Float(row.fetch("緯度"))
        longitude = Float(row.fetch("經度"))
        # The open data is WGS-84; everything the app draws is GCJ-02 (see Scripts/lib/gcj02.rb).
        latitude, longitude = GCJ02.from_wgs84(latitude, longitude)
        accessible = row.fetch("是否為無障礙用").to_s.strip == "是"
        record.fetch("stationAccessPoints") << {
          "id" => "#{canonical.fetch("id")}-#{label.empty? ? "exit" : label}",
          "name" => source_name,
          "kind" => "exit",
          "latitude" => latitude.round(6),
          "longitude" => longitude.round(6),
          "isAccessible" => accessible,
          "source" => "specificEntrance"
        }
      end

      stations = records.values.map do |record|
        record["stationAccessPoints"] = record.fetch("stationAccessPoints")
          .uniq { |point| point.fetch("id") }
          .sort_by { |point| point.fetch("id") }
        accessible_entrances = record.fetch("stationAccessPoints")
          .select { |point| point.fetch("isAccessible") }
          .map { |point| point.fetch("name") }
        unless accessible_entrances.empty?
          record["accessibility"] = {
            "source" => "data.taipei/taipei-metro-station-exits",
            "hasElevator" => nil,
            "hasEscalator" => nil,
            "hasWheelchairRamp" => nil,
            "hasTactilePath" => nil,
            "hasAccessibleRestroom" => nil,
            "elevatorLocations" => [],
            "accessibleEntrances" => accessible_entrances,
            "facilityNotes" => []
          }
        end
        normalize_station_arrays!(record)
      end.sort_by { |record| record.fetch("stationID") }

      {
        "schemaVersion" => 2,
        "cityID" => "7101",
        "version" => VERSION,
        "generatedAt" => GENERATED_AT,
        "rightsIDs" => %w[osm-metro-networks taipei-open-data].sort,
        "capabilities" => deep_copy(TAIPEI_CAPABILITIES),
        "coverage" => coverage_for(network.fetch("stations").length, stations),
        "stations" => stations
      }
    end

    def split_taipei_exit_name(value)
      return [TAIPEI_MAIN_STATION, value.delete_prefix(TAIPEI_MAIN_STATION)] if
        value.start_with?(TAIPEI_MAIN_STATION)

      match = TAIPEI_EXIT_PATTERN.match(value)
      raise BuildError, "unparsable Taipei exit name #{value.inspect}" unless match

      [match[:station], match[:label].to_s.strip]
    end

    def taipei_exit_rows
      @taipei_exit_rows ||= read_csv(File.join(root, "DataPacks", "sources", "7101", "station_exits.csv"))
    end

    def build_manifest(packs)
      pack_bytes = packs.to_h do |city_id, _pack|
        path = pack_path(city_id)
        [city_id, File.binread(path)]
      end

      {
        "schemaVersion" => 2,
        "generatedAt" => GENERATED_AT,
        "cities" => CATALOG_CITY_IDS.map do |city_id|
          network_station_count = network_station_count(city_id)
          if packs.key?(city_id)
            bytes = pack_bytes.fetch(city_id)
            pack = packs.fetch(city_id)
            {
              "cityID" => city_id,
              "version" => pack.fetch("version"),
              "sizeBytes" => bytes.bytesize,
              "sha256" => Digest::SHA256.hexdigest(bytes),
              "bundledResource" => "BundledCityPacks/#{city_id}.json",
              "downloadURL" => nil,
              "rightsIDs" => deep_copy(pack.fetch("rightsIDs")),
              "externalResources" => [],
              "capabilities" => deep_copy(pack.fetch("capabilities")),
              "coverage" => deep_copy(pack.fetch("coverage"))
            }
          else
            rights_ids = []
            rights_ids << "osm-metro-networks" if network_station_count.positive?
            rights_ids << "macau-official-landing-link" if city_id == "8200"
            {
              "cityID" => city_id,
              "version" => "source-pending",
              "sizeBytes" => 0,
              "sha256" => nil,
              "bundledResource" => nil,
              "downloadURL" => nil,
              "rightsIDs" => rights_ids.sort,
              "externalResources" => city_id == "8200" ? deep_copy(MACAU_EXTERNAL_RESOURCES) : [],
              "capabilities" => deep_copy(PENDING_CAPABILITIES),
              "coverage" => empty_coverage(network_station_count)
            }
          end
        end
      }
    end

    def source_metadata
      resources = SOURCE_FILES.map do |file_name, declaration|
        path = File.join(source_dir, file_name)
        rows = read_csv(path)
        entry = {
          "fileName" => file_name,
          "sourceURL" => declaration.fetch(:source_url),
          "datasetLandingPageURL" => declaration.fetch(:resource_url),
          "sizeBytes" => File.size(path),
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "csvRecordCount" => rows.length
        }
        case file_name
        when "mtr_lines_and_stations.csv"
          valid = rows.select { |row| present?(row["Station Code"]) }
          entry["dataRowCount"] = valid.length
          entry["stationCount"] = valid.map { |row| row["Station Code"] }.uniq.length
        when "light_rail_routes_and_stops.csv"
          entry["dataRowCount"] = rows.length
          entry["stationCount"] = rows.map { |row| row["Stop Code"] }.uniq.length
        when "barrier_free_facilities.csv"
          entry["dataRowCount"] = rows.length
          entry["stationGroupCount"] = rows.map { |row| row["Station_No"] }.compact.uniq.length
        when "barrier_free_facility_category.csv"
          entry["dataRowCount"] = rows.length
          entry["categoryCount"] = rows.map { |row| row["Item_Code"] }.compact.uniq.length
        end
        entry
      end

      {
        "schemaVersion" => 2,
        "cityID" => "8100",
        "snapshotAt" => GENERATED_AT,
        "rightsID" => "data-gov-hk-mtr",
        "termsURL" => "https://data.gov.hk/en/terms-and-conditions",
        "dataLicense" => DATA_GOV_HK_LICENSE.to_h,
        "realtimeAPIs" => deep_copy(REALTIME_APIS),
        "explicitCanonicalReferences" => [deep_copy(RACECOURSE_REFERENCE)],
        "resources" => resources
      }
    end

    def rights_inventory
      {
        "schemaVersion" => 2,
        "generatedAt" => GENERATED_AT,
        "supportedLicenses" => [
          "MIT",
          "ODbL-1.0",
          "LicenseRef-DATA-GOV-HK-1.2",
          "LicenseRef-OGDL-TW-1.0",
          "LicenseRef-External-Link-Only",
          "CC-BY-2.0",
          "CC0-1.0"
        ],
        "rights" => [
          {
            "id" => "justgo-generated-catalog",
            "kind" => "authoredMetadata",
            "scope" => "Generated catalog, rights inventory, and deterministic pack structure",
            "licenseSPDX" => "MIT",
            "licenseURL" => "https://opensource.org/license/mit",
            "sourceURL" => "https://github.com/e-rail/justgo",
            "attribution" => "JustGo contributors",
            "redistribution" => "Covered by the repository MIT license; third-party fields retain their separately declared terms."
          },
          {
            "id" => "osm-metro-networks",
            "kind" => "database",
            "scope" => "MetroNetworks station identifiers, names, lines, coordinates, and physical-track geometry",
            "licenseSPDX" => "ODbL-1.0",
            "licenseURL" => "https://opendatacommons.org/licenses/odbl/1-0/",
            "sourceURL" => "https://www.openstreetmap.org/",
            "attribution" => "OpenStreetMap contributors",
            "redistribution" => "Permitted under ODbL 1.0; preserve attribution and share-alike obligations for adapted databases."
          },
          {
            "id" => "data-gov-hk-mtr",
            "kind" => "dataset",
            "scope" => "DataPacks/sources/8100 CSV snapshots, sanitized Hong Kong station fields, and runtime MTR and Light Rail arrival APIs",
            "licenseSPDX" => "LicenseRef-DATA-GOV-HK-1.2",
            "licenseURL" => "https://data.gov.hk/en/terms-and-conditions",
            "sourceURL" => "https://data.gov.hk/en-data/dataset/mtr-data-routes-fares-barrier-free-facilities",
            "attribution" => "MTR Corporation Limited and DATA.GOV.HK",
            "redistribution" => "Custom DATA.GOV.HK Terms of Use v1.2 apply; attribution and source identification are required."
          },
          {
            "id" => "taipei-open-data",
            "kind" => "dataset",
            "scope" => "DataPacks/sources/7101 Taipei Metro station and station-exit datasets, and the exit names, positions and barrier-free flags derived from them",
            "licenseSPDX" => "LicenseRef-OGDL-TW-1.0",
            "licenseURL" => "https://data.gov.tw/license",
            "sourceURL" => "https://data.gov.tw/dataset/128428",
            "attribution" => "臺北大眾捷運股份有限公司 / 臺北市資料大平臺 (data.taipei)",
            "redistribution" => "Open Government Data License, Taiwan, version 1.0 permits redistribution, commercial use and derivative works. Attribution is mandatory: omitting it voids the licence grant retroactively."
          },
          {
            "id" => "beijing-official-landing-links",
            "kind" => "linkMetadata",
            "scope" => "Reviewed coverage states and official page/context URLs for all canonical Beijing app stations; no operator page text, schedules, facilities, exits, coordinates, images, or media are copied",
            "licenseSPDX" => "LicenseRef-External-Link-Only",
            "licenseURL" => "https://www.bjsubway.com/station/",
            "sourceURL" => "https://www.bjsubway.com/station/",
            "attribution" => "Beijing Subway, Beijing MTR, China Railway 12306, and the identified Beijing municipal authorities",
            "redistribution" => "Only factual station IDs, exact URLs, aliases, verification dates, and typed review outcomes are bundled. Provider-controlled page content remains external and is requested only after a user tap."
          },
          {
            "id" => "macau-official-landing-link",
            "kind" => "linkMetadata",
            "scope" => "HTTPS Macao LRT operator homepage link only; no operator facts or media are copied",
            "licenseSPDX" => "LicenseRef-External-Link-Only",
            "licenseURL" => "https://www.mlm.com.mo/en/",
            "sourceURL" => "https://www.mlm.com.mo/en/",
            "attribution" => "Macao Light Rapid Transit Corporation, Limited",
            "redistribution" => "Only factual link metadata is bundled. Linked content remains with its provider."
          },
          {
            "id" => "official-transit-resource-links",
            "kind" => "linkMetadata",
            "scope" => "Reviewed HTTPS target URLs, source-page URLs, providers, formats, scopes, and verification dates in the official transit resource catalog",
            "licenseSPDX" => "LicenseRef-External-Link-Only",
            "licenseURL" => "https://www.mtr.com.hk/en/customer/services/system_map.html",
            "sourceURL" => "https://www.mtr.com.hk/en/customer/services/system_map.html",
            "attribution" => "Official transit operators and government transport authorities identified per catalog record",
            "redistribution" => "Only factual link metadata is bundled. Linked pages and files remain with their providers and are opened only after user action."
          },
          {
            "id" => "media-jianguomen-ian-holton",
            "kind" => "mediaMetadata",
            "scope" => MEDIA.fetch("jianguomen").fetch("relativePath"),
            "licenseSPDX" => "CC-BY-2.0",
            "licenseURL" => MEDIA.fetch("jianguomen").fetch("licenseURL"),
            "sourceURL" => MEDIA.fetch("jianguomen").fetch("sourcePageURL"),
            "creator" => "Ian Holton",
            "attribution" => MEDIA.fetch("jianguomen").fetch("attribution"),
            "sourceSizeBytes" => 3_011_512,
            "sourceSHA1" => "682c2dd88704d654c79557a7a5f6d6f518d7f4b8",
            "bundledSizeBytes" => MEDIA.fetch("jianguomen").fetch("sizeBytes"),
            "bundledSHA256" => MEDIA.fetch("jianguomen").fetch("sha256"),
            "bundled" => true
          },
          {
            "id" => "media-central-qqhhss",
            "kind" => "mediaMetadata",
            "scope" => MEDIA.fetch("central").fetch("relativePath"),
            "licenseSPDX" => "CC0-1.0",
            "licenseURL" => MEDIA.fetch("central").fetch("licenseURL"),
            "sourceURL" => MEDIA.fetch("central").fetch("sourcePageURL"),
            "creator" => "Qqhhss",
            "attribution" => MEDIA.fetch("central").fetch("attribution"),
            "sourceSizeBytes" => 4_463_295,
            "sourceSHA1" => "23ad1d16a17cc4837b960e3606a3e91ee2cdf490",
            "bundledSizeBytes" => MEDIA.fetch("central").fetch("sizeBytes"),
            "bundledSHA256" => MEDIA.fetch("central").fetch("sha256"),
            "bundled" => true
          }
        ],
        "dataLicenses" => [DATA_GOV_HK_LICENSE.to_h],
        "files" => rights_file_inventory
      }
    end

    private

    def data_packs_dir
      File.join(root, "DataPacks")
    end

    def source_dir
      File.join(data_packs_dir, "sources", "8100")
    end

    def source_metadata_path
      File.join(source_dir, "metadata.json")
    end

    def rights_inventory_path
      File.join(data_packs_dir, "rights_inventory.json")
    end

    def third_party_notices_path
      File.join(root, "THIRD_PARTY_NOTICES.md")
    end

    def manifest_path
      File.join(data_packs_dir, "manifest.json")
    end

    def pack_path(city_id)
      File.join(root, "JustGo", "Resources", "BundledCityPacks", "#{city_id}.json")
    end

    def network_path(city_id)
      File.join(root, "JustGo", "Resources", "MetroNetworks", "#{city_id}.json")
    end

    def load_network(city_id)
      JSON.parse(File.read(network_path(city_id), encoding: "UTF-8"))
    end

    def network_station_count(city_id)
      return 0 unless File.file?(network_path(city_id))

      load_network(city_id).fetch("stations").length
    end

    def rights_file_inventory
      files = [
        {
          "path" => "DataPacks/manifest.json",
          "rightsIDs" => %w[
            justgo-generated-catalog osm-metro-networks data-gov-hk-mtr
            beijing-official-landing-links macau-official-landing-link
            media-jianguomen-ian-holton media-central-qqhhss taipei-open-data
          ].sort
        },
        {
          "path" => "DataPacks/rights_inventory.json",
          "rightsIDs" => ["justgo-generated-catalog"]
        },
        {
          "path" => "DataPacks/official_transit_resources.json",
          "rightsIDs" => %w[
            beijing-official-landing-links data-gov-hk-mtr justgo-generated-catalog
            official-transit-resource-links osm-metro-networks
          ].sort
        },
        {
          "path" => "DataPacks/sources/official-resources/hong_kong_index.json",
          "rightsIDs" => %w[
            data-gov-hk-mtr justgo-generated-catalog official-transit-resource-links
            osm-metro-networks
          ].sort
        },
        {
          "path" => "DataPacks/sources/official-resources/hong_kong_station_bindings.json",
          "rightsIDs" => %w[data-gov-hk-mtr justgo-generated-catalog osm-metro-networks].sort
        },
        {
          "path" => "DataPacks/sources/official-resources/beijing_station_information.json",
          "rightsIDs" => %w[
            beijing-official-landing-links justgo-generated-catalog
            official-transit-resource-links osm-metro-networks
          ].sort
        },
        {
          "path" => "DataPacks/sources/8100/metadata.json",
          "rightsIDs" => %w[justgo-generated-catalog data-gov-hk-mtr].sort
        },
        {
          "path" => "DataPacks/sources/7101/metadata.json",
          "rightsIDs" => %w[justgo-generated-catalog taipei-open-data].sort
        },
        {
          "path" => "JustGo/Resources/BundledCityPacks/7101.json",
          "rightsIDs" => %w[justgo-generated-catalog osm-metro-networks taipei-open-data].sort
        },
        {
          "path" => "THIRD_PARTY_NOTICES.md",
          "rightsIDs" => ["justgo-generated-catalog"]
        },
        {
          "path" => "JustGo/Resources/BundledCityPacks/1100.json",
          "rightsIDs" => %w[
            justgo-generated-catalog osm-metro-networks beijing-official-landing-links
            media-jianguomen-ian-holton
          ].sort
        },
        {
          "path" => "JustGo/Resources/BundledCityPacks/8100.json",
          "rightsIDs" => %w[
            justgo-generated-catalog osm-metro-networks data-gov-hk-mtr media-central-qqhhss
          ].sort
        },
        {
          "path" => "JustGo/Resources/LicensedMedia/beijing-jianguomen.jpg",
          "rightsIDs" => ["media-jianguomen-ian-holton"]
        },
        {
          "path" => "JustGo/Resources/LicensedMedia/hong-kong-central.jpg",
          "rightsIDs" => ["media-central-qqhhss"]
        }
      ]
      SOURCE_FILES.each_key do |file_name|
        files << {
          "path" => "DataPacks/sources/8100/#{file_name}",
          "rightsIDs" => ["data-gov-hk-mtr"]
        }
      end
      TAIPEI_SOURCE_FILES.each do |file_name|
        files << {
          "path" => "DataPacks/sources/7101/#{file_name}",
          "rightsIDs" => ["taipei-open-data"]
        }
      end
      Dir.glob(File.join(root, "JustGo", "Resources", "MetroNetworks", "*.json")).sort.each do |path|
        files << {
          "path" => path.delete_prefix("#{root}/"),
          "rightsIDs" => ["osm-metro-networks"]
        }
      end
      # DataPacks/universal/ republishes the catalog, networks, packs, and rights data as
      # one developer-facing document per city (Scripts/generate_universal_city_data.rb),
      # so every file carries the union of the aggregated sources' rights. The per-city
      # subset is embedded in each document and cross-checked by
      # Scripts/validate_universal_city_data.rb.
      universal_rights = %w[
        beijing-official-landing-links data-gov-hk-mtr justgo-generated-catalog
        macau-official-landing-link media-central-qqhhss media-jianguomen-ian-holton
        official-transit-resource-links osm-metro-networks taipei-open-data
      ].sort
      files << {
        "path" => "DataPacks/universal/index.json",
        "rightsIDs" => universal_rights
      }
      CATALOG_CITY_IDS.each do |city_id|
        files << {
          "path" => "DataPacks/universal/#{city_id}.json",
          "rightsIDs" => universal_rights
        }
      end
      files.sort_by { |entry| entry.fetch("path") }
    end

    def third_party_notices
      jianguomen = MEDIA.fetch("jianguomen")
      central = MEDIA.fetch("central")
      <<~MARKDOWN
        # Third-Party Notices

        This file is generated by `Scripts/generate_city_pack_manifest.rb` from the reviewed
        rights metadata. Do not edit it by hand.

        ## OpenStreetMap

        Canonical metro station identity and network geometry include data from OpenStreetMap.

        Copyright OpenStreetMap contributors. Licensed under the Open Data Commons Open Database
        License 1.0: https://opendatacommons.org/licenses/odbl/1-0/

        ## MTR Open Data Via DATA.GOV.HK

        The Hong Kong city pack is derived from the vendored MTR lines and stations, Light Rail
        routes and stops, barrier-free facilities, and barrier-free facility category snapshots.

        Data provider: MTR Corporation Limited. Distribution portal: DATA.GOV.HK. Reuse is governed
        by the DATA.GOV.HK Terms and Conditions of Use version 1.2:
        https://data.gov.hk/en/terms-and-conditions

        ## Taipei Metro Open Data Via data.taipei

        The Taipei city pack is derived from the vendored 臺北捷運車站出入口座標 and 臺北捷運車站資料
        snapshots: station entrance names, positions, and whether an entrance is the barrier-free one.

        Data provider: 臺北大眾捷運股份有限公司 (Taipei Rapid Transit Corporation). Distribution portal:
        臺北市資料大平臺 (data.taipei). Reuse is governed by the Open Government Data License, Taiwan,
        version 1.0, which requires this attribution to be retained:
        https://data.gov.tw/license

        ## Official Transit Resource Links

        The bundled official-resource catalog contains reviewed factual link metadata for transit
        operators and government transport authorities. Linked pages, PDFs, and images remain with
        their providers. After user action, JustGo renders reviewed pages in a non-persistent WebKit
        session and reviewed PDFs or images in memory-only native viewers. It does not copy,
        prefetch, persist, or redistribute their content.

        Hong Kong map metadata is reviewed from the official MTR System Map and Light Rail Street
        Map indexes:
        https://www.mtr.com.hk/en/customer/services/system_map.html
        https://www.mtr.com.hk/en/customer/services/stmap_index.html

        Beijing station-page metadata is reviewed from official Beijing Subway, 12306, municipal
        transport, development, and construction sources. All canonical app stations receive an
        exact-page or typed review outcome. The bundle contains URL metadata, not operator page
        text, schedules, facilities, exits, coordinates, images, or layouts. For 416 reviewed Beijing
        Subway IDs, Station Detail may request selected station text from the operator for temporary,
        non-persistent native display; the response remains subject to the operator's terms:
        https://www.bjsubway.com/station/
        https://www.12306.cn/mormhweb/czyd_2143/bj/201001/t20100119_1582.html
        https://jtw.beijing.gov.cn/sjtl/202111/t20211118_2540164.html
        https://fgw.beijing.gov.cn/gzdt/fgzs/gzdt/202112/t20211224_2571614.htm
        https://www.beijing.gov.cn/hudong/yonghu/static/zdb/xinxiang/detail.html?searchCode=zdb16223326024872299813
        https://ggzyfw.beijing.gov.cn/jyxxggjtbyqs/20240516/4526775.html

        ## Jianguomen Station Photo

        #{jianguomen.fetch("attribution")}

        Source description page: #{jianguomen.fetch("sourcePageURL")}

        Modification record: #{jianguomen.fetch("modifications")}

        ## Central Station Photo

        #{central.fetch("attribution")}

        Source description page: #{central.fetch("sourcePageURL")}

        Modification record: #{central.fetch("modifications")}
      MARKDOWN
    end

    def seed_sources!(refresh:)
      FileUtils.mkdir_p(source_dir)
      SOURCE_FILES.each do |file_name, declaration|
        destination = File.join(source_dir, file_name)
        next if File.file?(destination) && !refresh

        source = File.join(snapshot_dir, declaration.fetch(:snapshot))
        raise BuildError, "missing source snapshot #{source}" unless File.file?(source)

        FileUtils.cp(source, destination, preserve: false)
      end
    end

    def refuse_legacy_pack_tree!
      files = Dir.glob(File.join(data_packs_dir, "packs", "**", "*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
      return if files.empty?

      raise BuildError, "remove DataPacks/packs content before building (found #{files.length} files)"
    end

    def write_json(path, value)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "#{JSON.pretty_generate(value)}\n")
    end

    def read_csv(path)
      CSV.read(path, headers: true, encoding: "bom|utf-8")
    end

    def mtr_rows
      @mtr_rows ||= read_csv(File.join(source_dir, "mtr_lines_and_stations.csv"))
        .select { |row| present?(row["Station Code"]) }
    end

    def light_rail_rows
      @light_rail_rows ||= read_csv(File.join(source_dir, "light_rail_routes_and_stops.csv"))
        .select { |row| present?(row["Stop Code"]) }
    end

    def barrier_rows
      @barrier_rows ||= read_csv(File.join(source_dir, "barrier_free_facilities.csv"))
        .select { |row| present?(row["Station_No"]) && present?(row["Key"]) }
    end

    def category_rows
      @category_rows ||= read_csv(File.join(source_dir, "barrier_free_facility_category.csv"))
        .select { |row| present?(row["Item_Code"]) }
    end

    def category_index
      @category_index ||= category_rows.to_h { |row| [row.fetch("Item_Code"), row] }
    end

    def heavy_groups
      mtr_rows.group_by { |row| row.fetch("Station Code") }.sort.to_h
    end

    def light_rail_groups
      light_rail_rows.group_by { |row| row.fetch("Stop Code") }.sort.to_h
    end

    def canonical_station_index(stations)
      stations.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |station, index|
        [station["name"], station["nameEn"]].each do |name|
          key = normalize_name(name)
          index[key] << station unless key.empty?
        end
      end
    end

    def match_canonical!(index, chinese_name, english_name)
      candidates = [chinese_name, english_name].flat_map { |name| index[normalize_name(name)] }.uniq
      return candidates.first if candidates.length == 1

      raise BuildError,
        "canonical match for #{chinese_name.inspect}/#{english_name.inspect} yielded #{candidates.length} stations"
    end

    def normalize_name(value)
      value.to_s.unicode_normalize(:nfkc).downcase
        .gsub(/[^\p{Alnum}]+/u, "")
    end

    def base_station(station)
      {
        "stationID" => station.fetch("id"),
        "stationName" => station.fetch("name"),
        "stationNameEn" => station["nameEn"].to_s,
        "aliases" => [],
        "accessibility" => nil,
        "schedules" => [],
        "stationFacilities" => [],
        "externalResources" => [],
        "licensedMedia" => [],
        "liveArrivalReferences" => []
      }
    end

    def add_source_aliases(record, canonical, *source_names)
      canonical_names = [canonical["name"], canonical["nameEn"]].compact
      aliases = source_names.compact.reject do |source_name|
        canonical_names.any? { |canonical_name| normalize_name(source_name) == normalize_name(canonical_name) }
      end
      record["aliases"].concat(aliases)
    end

    def normalize_station_arrays!(record)
      record["aliases"] = record.fetch("aliases").reject(&:empty?).uniq.sort
      record["stationFacilities"] = record.fetch("stationFacilities").uniq { |facility| facility.fetch("id") }
        .sort_by { |facility| facility.fetch("id") }
      record["externalResources"] = record.fetch("externalResources")
        .uniq { |resource| [resource.fetch("kind"), resource.fetch("landingPageURL")] }
        .sort_by { |resource| [resource.fetch("kind"), resource.fetch("landingPageURL")] }
      record["licensedMedia"] = record.fetch("licensedMedia").sort_by { |media| media.fetch("relativePath") }
      record["liveArrivalReferences"] = record.fetch("liveArrivalReferences")
        .uniq { |reference| [reference["mode"], reference["lineCode"], reference["stationCode"], reference["lineID"]] }
        .sort_by do |reference|
          [reference.fetch("mode"), reference["lineCode"].to_s, reference.fetch("stationCode"), reference["lineID"].to_s]
        end
      record
    end

    def accessibility_record(rows)
      elevator_keys = %w[AJ3 AJ4 AJ8 AJ9]
      accessible_entrance_keys = %w[AJ1 AJ2 AJ3 AJ4 AJ8 AJ9]
      {
        "source" => "data.gov.hk/mtr-barrier-free-facilities",
        "hasElevator" => boolean_for(rows, elevator_keys),
        "hasEscalator" => nil,
        "hasWheelchairRamp" => boolean_for(rows, %w[AJ2 MJ2]),
        "hasTactilePath" => boolean_for(rows, %w[VJ1]),
        "hasAccessibleRestroom" => boolean_for(rows, %w[MJ4 MJ5 MJ6]),
        "elevatorLocations" => locations_for(rows, elevator_keys),
        "accessibleEntrances" => locations_for(rows, accessible_entrance_keys),
        "facilityNotes" => rows.select { |row| row["Value"] == "Y" }.map { |row| facility_note(row) }.uniq.sort
      }
    end

    def facility_records(station_id, rows)
      rows.select { |row| row["Value"] == "Y" }.map do |row|
        category = category_index.fetch(row.fetch("Key"))
        {
          "id" => "#{station_id}-#{row.fetch("Key").downcase}",
          "type" => facility_type(row.fetch("Key")),
          "name" => bilingual(category["Facility_En"], category["Facility_Zh"]),
          "locationText" => location_text(row)
        }
      end.sort_by { |facility| facility.fetch("id") }
    end

    def facility_type(key)
      case key
      when "AJ2", "MJ2" then "ramp"
      when "AJ3", "AJ4", "AJ8", "AJ9" then "elevator"
      when "MJ4", "MJ5", "MJ6" then "accessibleRestroom"
      when "VJ1", "VJ3", "VIn1" then "tactilePath"
      when "VJ2", "VJ4", "VJ7" then "audioAnnouncement"
      when /^HJ[2-8]$/ then "visualDisplay"
      when "AJ5", "AJ6", "AJ7", "MJ1", "MJ3", "MJ7" then "wheelchairBoarding"
      else "general"
      end
    end

    def boolean_for(rows, keys)
      matching = rows.select { |row| keys.include?(row["Key"]) }
      return nil if matching.empty?

      matching.any? { |row| row["Value"] == "Y" }
    end

    def locations_for(rows, keys)
      rows.select { |row| keys.include?(row["Key"]) && row["Value"] == "Y" }
        .map { |row| location_text(row) }.compact.uniq.sort
    end

    def facility_note(row)
      category = category_index.fetch(row.fetch("Key"))
      name = bilingual(category["Facility_En"], category["Facility_Zh"])
      location = location_text(row)
      location ? "#{name}: #{location}" : name
    end

    def location_text(row)
      values = [row["AJTextEn"], row["AJTextZh"]].select { |value| present?(value) }
        .map { |value| CGI.unescapeHTML(value) }.uniq
      values.empty? ? nil : values.join(" / ")
    end

    def bilingual(english, chinese)
      [english, chinese].select { |value| present?(value) }
        .map { |value| CGI.unescapeHTML(value) }.uniq.join(" / ")
    end

    def live_reference(mode, line_code, station_code, line_index, route_reference: line_code)
      line = line_index.fetch(route_reference.downcase) do
        raise BuildError, "canonical line missing for #{route_reference}"
      end
      {
        "mode" => mode,
        "lineCode" => line_code,
        "stationCode" => station_code,
        "lineID" => line.fetch("id"),
        "lineName" => clean_line_name(line.fetch("name")),
        "lineNameEn" => clean_line_name(line.fetch("nameEn")),
        "colorHex" => line.fetch("colorHex")
      }
    end

    def clean_line_name(value)
      value.sub(/\s*\([^)]*\)?\z/, "").strip
    end

    def destination_names
      names = heavy_groups.keys.sort.to_h do |station_code|
        row = heavy_groups.fetch(station_code).first
        [station_code, { "name" => row.fetch("Chinese Name"), "nameEn" => row.fetch("English Name") }]
      end
      names[RACECOURSE_REFERENCE.fetch("stationCode")] = {
        "name" => RACECOURSE_REFERENCE.fetch("stationName"),
        "nameEn" => RACECOURSE_REFERENCE.fetch("stationNameEn")
      }
      names.sort.to_h
    end

    def external_resource(kind, title, url, provider)
      {
        "kind" => kind,
        "title" => title,
        "landingPageURL" => url,
        "provider" => provider
      }
    end

    def coverage_for(network_count, stations)
      metric = ->(covered) { { "covered" => covered, "total" => network_count } }
      {
        "networkStations" => network_count,
        "matchedStations" => metric.call(stations.length),
        "accessibility" => metric.call(stations.count { |station| !station["accessibility"].nil? }),
        "staticSchedules" => metric.call(stations.count { |station| !station.fetch("schedules").empty? }),
        "liveArrivals" => metric.call(stations.count { |station| !station.fetch("liveArrivalReferences").empty? }),
        # Operator hyperlinks live in the independent bundled resource catalog.
        # Compatibility URL fields in a city pack never count as included coverage.
        "externalLayouts" => metric.call(0),
        "licensedMedia" => metric.call(stations.count { |station| !station.fetch("licensedMedia").empty? }),
        "verifiedTransferContexts" => metric.call(stations.count do |station|
          !Array(station["verifiedTransferContexts"]).empty?
        end)
      }
    end

    def empty_coverage(network_count)
      metric = { "covered" => 0, "total" => network_count }
      {
        "networkStations" => network_count,
        "matchedStations" => deep_copy(metric),
        "accessibility" => deep_copy(metric),
        "staticSchedules" => deep_copy(metric),
        "liveArrivals" => deep_copy(metric),
        "externalLayouts" => deep_copy(metric),
        "licensedMedia" => deep_copy(metric),
        "verifiedTransferContexts" => deep_copy(metric)
      }
    end

    def present?(value)
      !value.to_s.strip.empty?
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
