# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "open3"
require "uri"
require_relative "oss_city_pack_pipeline"

module OSSDataValidators
  class ValidationError < StandardError; end

  SUPPORTED_LICENSES = %w[
    MIT
    ODbL-1.0
    LicenseRef-DATA-GOV-HK-1.2
    LicenseRef-OGDL-TW-1.0
    LicenseRef-External-Link-Only
    CC-BY-2.0
    CC0-1.0
  ].freeze
  MEDIA_LICENSES = %w[CC-BY-2.0 CC0-1.0].freeze
  REQUIRED_COVERAGE_KEYS = %w[
    networkStations matchedStations accessibility staticSchedules liveArrivals
    externalLayouts licensedMedia verifiedTransferContexts
  ].freeze
  REQUIRED_STATION_KEYS = %w[
    stationID stationName stationNameEn aliases accessibility schedules stationFacilities
    externalResources licensedMedia liveArrivalReferences
  ].freeze
  # Optional in the pack schema and in `OfficialCityPackService`; present where a city has an
  # open-data source for its entrances, absent everywhere else.
  OPTIONAL_STATION_KEYS = %w[stationAccessPoints].freeze
  REQUIRED_ACCESS_POINT_KEYS = %w[
    id name kind latitude longitude isAccessible source
  ].freeze
  ACCESS_POINT_KINDS = %w[entrance exit elevator escalator unknown].freeze
  ACCESS_POINT_SOURCES = %w[specificEntrance localStationData].freeze
  REQUIRED_MEDIA_KEYS = %w[
    kind title relativePath mimeType sizeBytes sha256 sourcePageURL creator licenseSPDX
    licenseURL attribution modifications
  ].freeze
  REQUIRED_LIVE_REFERENCE_KEYS = %w[
    mode lineCode stationCode lineID lineName lineNameEn colorHex
  ].freeze
  REQUIRED_DATA_LICENSE_KEYS = %w[
    rightsID datasetName termsURL attribution snapshotDate
    redistributionEvidenceURL redistributionEvidence
  ].freeze
  BUNDLED_CITY_IDS = %w[1100 7101 8100].freeze
  EXTERNAL_LANDING_PAGES = {
    "1100" => %w[
      https://www.bjsubway.com/station/xltcx/
      https://www.mtr.bj.cn/service/line/
    ],
    "8100" => %w[https://www.mtr.com.hk/en/customer/services/system_map.html],
    "8200" => %w[https://www.mlm.com.mo/en/]
  }.freeze
  FORBIDDEN_EXTERNAL_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif .svg .pdf].freeze
  COMMONS_RUNTIME_HOSTS = %w[commons.wikimedia.org upload.wikimedia.org].freeze
  RIGHTS_HOSTS = %w[
    creativecommons.org
    commons.wikimedia.org
    data.gov.hk
    data.gov.tw
    github.com
    opensource.org
    opendatacommons.org
    service.shmetro.com
    www.bjsubway.com
    www.gzmtr.com
    www.mlm.com.mo
    www.mtr.com.hk
    www.openstreetmap.org
  ].freeze
  class BaseValidator
    attr_reader :root

    def initialize(root: File.expand_path("../..", __dir__))
      @root = File.expand_path(root)
    end

    private

    def fail_validation(message)
      raise ValidationError, message
    end

    def load_json(path)
      JSON.parse(File.read(path, encoding: "UTF-8"))
    rescue Errno::ENOENT
      fail_validation("missing #{relative(path)}")
    rescue JSON::ParserError => error
      fail_validation("invalid JSON in #{relative(path)}: #{error.message}")
    end

    def relative(path)
      path.delete_prefix("#{root}/")
    end

    def safe_relative_path?(value)
      return false unless value.is_a?(String) && !value.empty?
      return false if value.include?("\\") || value.start_with?("/")

      parts = value.split("/")
      !parts.any? { |part| part.empty? || part == "." || part == ".." }
    end

    def https_uri(value, label)
      uri = URI.parse(value.to_s)
      fail_validation("#{label} must use HTTPS") unless uri.scheme&.downcase == "https"
      fail_validation("#{label} must have a host") if uri.host.to_s.empty?
      fail_validation("#{label} must not contain userinfo") if uri.user || uri.password
      uri
    rescue URI::InvalidURIError
      fail_validation("#{label} is not a valid URL")
    end

    def exact_keys!(hash, expected, label, optional: [])
      fail_validation("#{label} must be an object") unless hash.is_a?(Hash)
      missing = expected - hash.keys
      extra = hash.keys - expected - optional
      fail_validation("#{label} missing keys: #{missing.join(", ")}") unless missing.empty?
      fail_validation("#{label} has unsupported keys: #{extra.join(", ")}") unless extra.empty?
    end
  end

  class RightsValidator < BaseValidator
    def validate!
      inventory = load_json(File.join(root, "DataPacks", "rights_inventory.json"))
      exact_keys!(
        inventory,
        %w[schemaVersion generatedAt supportedLicenses rights dataLicenses files],
        "rights inventory"
      )
      fail_validation("rights inventory schemaVersion must be 2") unless inventory["schemaVersion"] == 2
      unless inventory["supportedLicenses"] == SUPPORTED_LICENSES
        fail_validation("rights inventory supportedLicenses must equal the reviewed allowlist")
      end

      rights = inventory["rights"]
      fail_validation("rights inventory rights must be a non-empty array") unless rights.is_a?(Array) && !rights.empty?
      ids = rights.map { |item| item["id"] }
      fail_validation("rights inventory IDs must be unique") unless ids.length == ids.uniq.length
      rights.each { |item| validate_right!(item) }
      osm = rights.find { |item| item["id"] == "osm-metro-networks" }
      fail_validation("OSM rights scope must cover geometry") unless osm&.fetch("scope", "")&.include?("geometry")
      validate_data_licenses!(inventory.fetch("dataLicenses"), rights)

      validate_no_legacy_pack_tree!
      files = inventory["files"]
      validate_file_inventory!(files, ids)

      declarations = licensed_media_declarations
      validate_source_metadata!
      validate_scoped_files!(declarations, rights, files)
      validate_pack_rights!(ids)
      true
    end

    def validate_history!
      output, error, status = Open3.capture3(
        "git", "rev-list", "--objects", "--all",
        chdir: root
      )
      fail_validation("could not inspect Git history: #{error.strip}") unless status.success?
      historical = output.lines.each_with_object([]) do |line, result|
        _object_id, path = line.strip.split(" ", 2)
        result << path if path == "DataPacks/packs" || path&.start_with?("DataPacks/packs/")
      end
      unless historical.empty?
        fail_validation("Git history still contains DataPacks/packs objects (#{historical.length})")
      end
      true
    end

    private

    def validate_right!(item)
      %w[id kind scope licenseSPDX licenseURL sourceURL attribution].each do |key|
        fail_validation("rights item missing #{key}") if item[key].to_s.empty?
      end
      license = item.fetch("licenseSPDX")
      fail_validation("unsupported license #{license}") unless SUPPORTED_LICENSES.include?(license)
      license_uri = https_uri(item.fetch("licenseURL"), "rights #{item.fetch("id")} licenseURL")
      source_uri = https_uri(item.fetch("sourceURL"), "rights #{item.fetch("id")} sourceURL")
      unless RIGHTS_HOSTS.include?(license_uri.host.downcase) && RIGHTS_HOSTS.include?(source_uri.host.downcase)
        fail_validation("rights #{item.fetch("id")} uses an unallowlisted domain")
      end
      return unless item.fetch("kind") == "mediaMetadata"

      fail_validation("media right missing creator") if item["creator"].to_s.empty?
      fail_validation("unsupported media license #{license}") unless MEDIA_LICENSES.include?(license)
      fail_validation("media bundled flag must be boolean") unless [true, false].include?(item["bundled"])
    end

    def validate_source_metadata!
      metadata_path = File.join(root, "DataPacks", "sources", "8100", "metadata.json")
      metadata = load_json(metadata_path)
      exact_keys!(
        metadata,
        %w[
          schemaVersion cityID snapshotAt rightsID termsURL dataLicense realtimeAPIs
          explicitCanonicalReferences resources
        ],
        "source metadata"
      )
      fail_validation("source metadata schemaVersion must be 2") unless metadata["schemaVersion"] == 2
      fail_validation("source metadata cityID must be 8100") unless metadata["cityID"] == "8100"
      terms = https_uri(metadata["termsURL"], "source metadata termsURL")
      fail_validation("source metadata termsURL host is not allowed") unless terms.host == "data.gov.hk"
      expected_license = OSSCityPackPipeline::DATA_GOV_HK_LICENSE.to_h
      fail_validation("source metadata dataLicense is inconsistent") unless metadata["dataLicense"] == expected_license
      unless metadata["realtimeAPIs"] == OSSCityPackPipeline::REALTIME_APIS
        fail_validation("source metadata realtime API inventory is inconsistent")
      end
      metadata.fetch("realtimeAPIs").each do |api|
        endpoint = https_uri(api.fetch("endpointURL"), "realtime API endpointURL")
        landing = https_uri(api.fetch("datasetLandingPageURL"), "realtime API datasetLandingPageURL")
        dictionary = https_uri(api.fetch("dataDictionaryURL"), "realtime API dataDictionaryURL")
        unless endpoint.host == "rt.data.gov.hk" && landing.host == "data.gov.hk" &&
            dictionary.host == "opendata.mtr.com.hk"
          fail_validation("realtime API metadata uses an unallowlisted host")
        end
      end
      unless metadata["explicitCanonicalReferences"] == [OSSCityPackPipeline::RACECOURSE_REFERENCE]
        fail_validation("source metadata canonical references are inconsistent")
      end

      resources = metadata["resources"]
      fail_validation("source metadata resources must be an array") unless resources.is_a?(Array)
      expected_names = OSSCityPackPipeline::SOURCE_FILES.keys
      names = resources.map { |resource| resource["fileName"] }
      fail_validation("source metadata file list is inconsistent") unless names == expected_names

      resources.each do |resource|
        file_name = resource.fetch("fileName")
        fail_validation("source metadata path is unsafe") unless File.basename(file_name) == file_name
        path = File.join(root, "DataPacks", "sources", "8100", file_name)
        fail_validation("missing vendored source #{file_name}") unless File.file?(path)
        fail_validation("source size mismatch for #{file_name}") unless resource["sizeBytes"] == File.size(path)
        actual_sha = Digest::SHA256.file(path).hexdigest
        fail_validation("source checksum mismatch for #{file_name}") unless resource["sha256"] == actual_sha
        source_uri = https_uri(resource["sourceURL"], "#{file_name} sourceURL")
        landing_uri = https_uri(resource["datasetLandingPageURL"], "#{file_name} datasetLandingPageURL")
        fail_validation("#{file_name} source host is not allowed") unless source_uri.host == "opendata.mtr.com.hk"
        fail_validation("#{file_name} landing host is not allowed") unless landing_uri.host == "data.gov.hk"

        rows = CSV.read(path, headers: true, encoding: "bom|utf-8")
        fail_validation("CSV record count mismatch for #{file_name}") unless resource["csvRecordCount"] == rows.length
      end

      barrier = resources.find { |resource| resource["fileName"] == "barrier_free_facilities.csv" }
      fail_validation("accessibility source must declare 99 station groups") unless barrier["stationGroupCount"] == 99
    end

    def validate_data_licenses!(licenses, rights)
      unless licenses.is_a?(Array) && licenses == [OSSCityPackPipeline::DATA_GOV_HK_LICENSE.to_h]
        fail_validation("rights inventory dataLicenses must equal the reviewed metadata")
      end

      licenses.each do |license|
        exact_keys!(license, REQUIRED_DATA_LICENSE_KEYS, "data license")
        rights_id = license.fetch("rightsID")
        right = rights.find { |item| item["id"] == rights_id }
        fail_validation("data license has unknown rightsID #{rights_id}") unless right
        fail_validation("data license #{rights_id} must reference a dataset right") unless right["kind"] == "dataset"
        fail_validation("data license #{rights_id} datasetName is empty") if license["datasetName"].to_s.empty?
        fail_validation("data license #{rights_id} attribution is empty") if license["attribution"].to_s.empty?
        fail_validation("data license #{rights_id} snapshotDate is invalid") unless license["snapshotDate"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        fail_validation("data license #{rights_id} evidence is empty") if license["redistributionEvidence"].to_s.empty?
        terms = https_uri(license["termsURL"], "data license #{rights_id} termsURL")
        evidence = https_uri(
          license["redistributionEvidenceURL"],
          "data license #{rights_id} redistributionEvidenceURL"
        )
        unless terms.host == "data.gov.hk" && evidence.host == "data.gov.hk"
          fail_validation("data license #{rights_id} evidence host is not allowed")
        end
      end
    end

    def licensed_media_declarations
      Dir.glob(File.join(root, "JustGo", "Resources", "BundledCityPacks", "*.json")).sort.flat_map do |path|
        load_json(path).fetch("stations", []).flat_map { |station| Array(station["licensedMedia"]) }
      end
    end

    def validate_file_inventory!(files, known_ids)
      fail_validation("rights inventory files must be a non-empty array") unless files.is_a?(Array) && !files.empty?
      paths = files.map { |entry| entry["path"] }
      fail_validation("rights inventory file paths must be unique") unless paths.length == paths.uniq.length
      fail_validation("rights inventory files must be sorted") unless paths == paths.sort

      files.each do |entry|
        exact_keys!(entry, %w[path rightsIDs], "rights file entry")
        path = entry.fetch("path")
        fail_validation("rights file path is unsafe: #{path}") unless safe_relative_path?(path)
        rights_ids = entry.fetch("rightsIDs")
        fail_validation("rights file #{path} must declare rights IDs") unless rights_ids.is_a?(Array) && !rights_ids.empty?
        fail_validation("rights file #{path} rights IDs must be unique and sorted") unless rights_ids == rights_ids.uniq.sort
        unknown = rights_ids - known_ids
        fail_validation("rights file #{path} has unknown rights IDs: #{unknown.join(", ")}") unless unknown.empty?
        expected_rights = expected_rights_for(path)
        unless expected_rights && rights_ids == expected_rights
          fail_validation("rights file #{path} has an incorrect rights assignment")
        end
        fail_validation("rights file #{path} does not exist") unless File.file?(File.join(root, path))
      end

      actual = scoped_asset_paths
      missing = actual - paths
      stale = paths - actual
      fail_validation("structured/bundled files missing rights declarations: #{missing.join(", ")}") unless missing.empty?
      fail_validation("rights inventory declares files outside the reviewed scope: #{stale.join(", ")}") unless stale.empty?
    end

    def validate_no_legacy_pack_tree!
      legacy_files = Dir.glob(File.join(root, "DataPacks", "packs", "**", "*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
      fail_validation("DataPacks/packs content is forbidden") unless legacy_files.empty?
      validate_no_tracked_legacy_files!
    end

    def scoped_asset_paths
      paths = []
      paths.concat(Dir.glob(File.join(root, "DataPacks", "**", "*.{json,csv}")))
      paths.concat(Dir.glob(File.join(root, "JustGo", "Resources", "BundledCityPacks", "**", "*.json")))
      paths.concat(Dir.glob(File.join(root, "JustGo", "Resources", "MetroNetworks", "**", "*.json")))
      paths.concat(Dir.glob(File.join(root, "JustGo", "Resources", "LicensedMedia", "**", "*")))
      paths << File.join(root, "THIRD_PARTY_NOTICES.md")
      paths.select { |path| File.file?(path) }.map { |path| relative(path) }.uniq.sort
    end

    def validate_scoped_files!(declarations, rights, files)
      data_files = Dir.glob(File.join(root, "DataPacks", "**", "*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
      data_files.each do |path|
        extension = File.extname(path).downcase
        fail_validation("undeclared binary in #{relative(path)}") unless %w[.json .csv .md].include?(extension)
        sample = File.binread(path, 8192)
        fail_validation("undeclared binary in #{relative(path)}") if sample.include?("\x00")
      end

      media_dir = File.join(root, "JustGo", "Resources", "LicensedMedia")
      media_files = Dir.glob(File.join(media_dir, "**", "*"), File::FNM_DOTMATCH)
        .select { |path| File.file?(path) }
      media_files.each do |path|
        next if File.extname(path).downcase == ".json"

        relative_path = path.delete_prefix("#{File.join(root, "JustGo", "Resources")}/")
        declaration = declarations.find { |media| media["relativePath"] == relative_path }
        fail_validation("undeclared binary in #{relative(path)}") unless declaration
        right = rights.find { |item| item["scope"] == relative_path }
        fail_validation("binary #{relative_path} has no rights declaration") unless right
        inventory_entry = files.find { |entry| entry["path"] == relative(path) }
        unless inventory_entry&.fetch("rightsIDs", [])&.include?(right.fetch("id"))
          fail_validation("binary #{relative_path} rights inventory is inconsistent")
        end
        fail_validation("binary #{relative_path} is marked unbundled") unless right["bundled"] == true
        fail_validation("binary size mismatch for #{relative_path}") unless declaration["sizeBytes"] == File.size(path)
        digest = Digest::SHA256.file(path).hexdigest
        fail_validation("binary checksum mismatch for #{relative_path}") unless declaration["sha256"] == digest
        fail_validation("rights evidence size mismatch for #{relative_path}") unless right["bundledSizeBytes"] == File.size(path)
        fail_validation("rights evidence checksum mismatch for #{relative_path}") unless right["bundledSHA256"] == digest
      end
    end

    def validate_no_tracked_legacy_files!
      output, _error, status = Open3.capture3("git", "ls-files", "--", "DataPacks/packs", chdir: root)
      return unless status.success?

      present = output.lines
        .map(&:strip)
        .reject(&:empty?)
        .select { |path| File.exist?(File.join(root, path)) }
      fail_validation("tracked DataPacks/packs content is forbidden") unless present.empty?
    end

    def validate_pack_rights!(known_ids)
      Dir.glob(File.join(root, "JustGo", "Resources", "BundledCityPacks", "*.json")).sort.each do |path|
        pack = load_json(path)
        unknown = Array(pack["rightsIDs"]) - known_ids
        fail_validation("#{relative(path)} has unknown rights IDs: #{unknown.join(", ")}") unless unknown.empty?
        pack.fetch("stations", []).each do |station|
          Array(station["licensedMedia"]).each do |media|
            license = media["licenseSPDX"]
            fail_validation("unsupported media license #{license}") unless MEDIA_LICENSES.include?(license)
            right = load_json(File.join(root, "DataPacks", "rights_inventory.json")).fetch("rights")
              .find { |item| item["scope"] == media["relativePath"] }
            fail_validation("media #{media["relativePath"]} has no rights declaration") unless right
            fail_validation("media license mismatch for #{media["relativePath"]}") unless right["licenseSPDX"] == license
            unless Array(pack["rightsIDs"]).include?(right.fetch("id"))
              fail_validation("pack omits media right for #{media["relativePath"]}")
            end
          end
        end
      end
    end

    def expected_rights_for(path)
      return ["osm-metro-networks"] if path.match?(%r{\AJustGo/Resources/MetroNetworks/[^/]+\.json\z})
      return ["data-gov-hk-mtr"] if path.match?(%r{\ADataPacks/sources/8100/[^/]+\.csv\z})
      return ["taipei-open-data"] if path.match?(%r{\ADataPacks/sources/7101/[^/]+\.csv\z})
      # Universal city documents aggregate every reviewed source, so each carries the full
      # rights union; the per-city subset lives inside the document itself.
      if path.match?(%r{\ADataPacks/universal/[^/]+\.json\z})
        return %w[
          beijing-official-landing-links data-gov-hk-mtr justgo-generated-catalog
          macau-official-landing-link
          official-transit-resource-links osm-metro-networks taipei-open-data
        ].sort
      end

      {
        "DataPacks/manifest.json" => %w[
          beijing-official-landing-links data-gov-hk-mtr justgo-generated-catalog
          macau-official-landing-link
          osm-metro-networks taipei-open-data
        ].sort,
        "DataPacks/rights_inventory.json" => ["justgo-generated-catalog"],
        "DataPacks/official_transit_resources.json" => %w[
          beijing-official-landing-links data-gov-hk-mtr justgo-generated-catalog
          official-transit-resource-links osm-metro-networks
        ].sort,
        "DataPacks/sources/official-resources/shanghai_station_information.json" => %w[
          justgo-generated-catalog official-transit-resource-links osm-metro-networks
          shanghai-official-landing-links
        ].sort,
        "DataPacks/sources/official-resources/guangzhou_station_information.json" => %w[
          guangzhou-official-station-references justgo-generated-catalog osm-metro-networks
        ].sort,
        "DataPacks/sources/official-resources/beijing_station_information.json" => %w[
          beijing-official-landing-links justgo-generated-catalog
          official-transit-resource-links osm-metro-networks
        ].sort,
        "DataPacks/sources/official-resources/hong_kong_index.json" => %w[
          data-gov-hk-mtr justgo-generated-catalog official-transit-resource-links
          osm-metro-networks
        ].sort,
        "DataPacks/sources/official-resources/hong_kong_station_bindings.json" => %w[
          data-gov-hk-mtr justgo-generated-catalog osm-metro-networks
        ].sort,
        "DataPacks/sources/8100/metadata.json" => %w[data-gov-hk-mtr justgo-generated-catalog].sort,
        "DataPacks/sources/7101/metadata.json" => %w[justgo-generated-catalog taipei-open-data].sort,
        "JustGo/Resources/BundledCityPacks/7101.json" => %w[
          justgo-generated-catalog osm-metro-networks taipei-open-data
        ].sort,
        "THIRD_PARTY_NOTICES.md" => ["justgo-generated-catalog"],
        "JustGo/Resources/BundledCityPacks/1100.json" => %w[
          beijing-official-landing-links justgo-generated-catalog
          osm-metro-networks
        ].sort,
        "JustGo/Resources/BundledCityPacks/8100.json" => %w[
          data-gov-hk-mtr justgo-generated-catalog osm-metro-networks
        ].sort
      }[path]
    end
  end

  class CityPackValidator < BaseValidator
    def validate!
      manifest = load_json(File.join(root, "DataPacks", "manifest.json"))
      fail_validation("manifest schemaVersion must be 2") unless manifest["schemaVersion"] == 2
      cities = manifest["cities"]
      fail_validation("manifest cities must be an array") unless cities.is_a?(Array)
      ids = cities.map { |city| city["cityID"] }
      unless ids == OSSCityPackPipeline::CATALOG_CITY_IDS
        fail_validation("manifest must contain all 58 catalog cities in stable order")
      end
      fail_validation("manifest downloadURL values must all be null") unless cities.all? { |city| city["downloadURL"].nil? }
      known_rights_ids = load_json(File.join(root, "DataPacks", "rights_inventory.json"))
        .fetch("rights").map { |right| right.fetch("id") }
      cities.each do |city|
        exact_keys!(
          city,
          %w[cityID version sizeBytes sha256 bundledResource downloadURL rightsIDs externalResources capabilities coverage],
          "manifest city #{city["cityID"]}"
        )
        rights_ids = city.fetch("rightsIDs")
        unless rights_ids.is_a?(Array) && rights_ids == rights_ids.uniq.sort
          fail_validation("#{city.fetch("cityID")} manifest rightsIDs must be unique and sorted")
        end
        unknown = rights_ids - known_rights_ids
        fail_validation("#{city.fetch("cityID")} manifest has unknown rights IDs") unless unknown.empty?
        resources = city.fetch("externalResources")
        unless resources.is_a?(Array)
          fail_validation("#{city.fetch("cityID")} manifest externalResources must be an array")
        end
        resources.each { |resource| validate_external_resource!(city.fetch("cityID"), resource) }
      end

      bundled = cities.select { |city| !city["bundledResource"].nil? }
      unless bundled.map { |city| city["cityID"] }.sort == BUNDLED_CITY_IDS
        fail_validation("only #{BUNDLED_CITY_IDS.join(", ")} may be bundled")
      end
      (cities - bundled).each { |city| validate_pending_city!(city) }
      bundled.each { |city| validate_bundled_city!(city) }
      RightsValidator.new(root: root).validate!
      true
    end

    private

    def validate_pending_city!(city)
      city_id = city.fetch("cityID")
      fail_validation("#{city_id} pending version is invalid") unless city["version"] == "source-pending"
      fail_validation("#{city_id} pending sizeBytes must be 0") unless city["sizeBytes"] == 0
      fail_validation("#{city_id} pending sha256 must be null") unless city["sha256"].nil?
      expected_rights = []
      expected_rights << "osm-metro-networks" if network_station_count(city_id).positive?
      expected_rights << "macau-official-landing-link" if city_id == "8200"
      expected_rights.sort!
      fail_validation("#{city_id} pending rightsIDs are inconsistent") unless city["rightsIDs"] == expected_rights
      expected_resources = city_id == "8200" ? OSSCityPackPipeline::MACAU_EXTERNAL_RESOURCES : []
      fail_validation("#{city_id} pending external resources are inconsistent") unless city["externalResources"] == expected_resources
      unless city.fetch("capabilities").values.all? { |value| value == "source_pending" }
        fail_validation("#{city_id} non-bundled capabilities must be source_pending")
      end
      expected = empty_coverage(network_station_count(city_id))
      fail_validation("#{city_id} pending coverage is inconsistent") unless city["coverage"] == expected
    end

    def validate_bundled_city!(city)
      city_id = city.fetch("cityID")
      expected_resource = "BundledCityPacks/#{city_id}.json"
      unless city["bundledResource"] == expected_resource
        fail_validation("#{city_id} bundledResource must be #{expected_resource}")
      end
      fail_validation("#{city_id} bundled resources must be station-scoped") unless city["externalResources"] == []
      resource = city.fetch("bundledResource")
      fail_validation("#{city_id} bundledResource is unsafe") unless safe_relative_path?(resource)
      pack_path = File.join(root, "JustGo", "Resources", resource)
      fail_validation("missing bundled pack #{resource}") unless File.file?(pack_path)
      bytes = File.binread(pack_path)
      fail_validation("#{city_id} sizeBytes must be positive") unless city["sizeBytes"].is_a?(Integer) && city["sizeBytes"].positive?
      fail_validation("#{city_id} sha256 must be lowercase hex") unless city["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      fail_validation("#{city_id} sizeBytes mismatch") unless city["sizeBytes"] == bytes.bytesize
      fail_validation("#{city_id} sha256 mismatch") unless city["sha256"] == Digest::SHA256.hexdigest(bytes)

      pack = load_json(pack_path)
      validate_pack_root!(pack, city, pack_path)
      fail_validation("#{city_id} manifest and pack rightsIDs differ") unless city["rightsIDs"] == pack["rightsIDs"]
      network = load_network(city_id)
      canonical_ids = network.fetch("stations").map { |station| station.fetch("id") }
      station_ids = pack.fetch("stations").map { |station| station["stationID"] }
      fail_validation("#{city_id} stations must use stable stationID ordering") unless station_ids == station_ids.sort
      fail_validation("#{city_id} stationIDs must be unique") unless station_ids.length == station_ids.uniq.length
      unknown_ids = station_ids - canonical_ids
      fail_validation("#{city_id} has non-canonical stationIDs: #{unknown_ids.join(", ")}") unless unknown_ids.empty?
      pack.fetch("stations").each { |station| validate_station!(city_id, station, pack_path, network) }
      validate_access_point_frame!(city_id, pack, network)

      computed = coverage_for(canonical_ids.length, pack.fetch("stations"))
      fail_validation("#{city_id} pack coverage is inconsistent") unless pack["coverage"] == computed
      fail_validation("#{city_id} manifest coverage is inconsistent") unless city["coverage"] == computed
      validate_city_expectations!(city_id, pack, network)
    end

    def validate_pack_root!(pack, city, pack_path)
      required = %w[schemaVersion cityID version generatedAt rightsIDs capabilities coverage stations]
      exact_keys!(pack, required, relative(pack_path), optional: ["destinationNames"])
      fail_validation("pack schemaVersion must be 2") unless pack["schemaVersion"] == 2
      fail_validation("pack cityID mismatch") unless pack["cityID"] == city["cityID"]
      fail_validation("pack version mismatch") unless pack["version"] == city["version"]
      fail_validation("pack generatedAt must be deterministic") unless pack["generatedAt"] == OSSCityPackPipeline::GENERATED_AT
      unless pack["rightsIDs"].is_a?(Array) && !pack["rightsIDs"].empty? &&
          pack["rightsIDs"] == pack["rightsIDs"].uniq.sort
        fail_validation("pack rightsIDs must be a non-empty, unique, sorted array")
      end
      fail_validation("pack capabilities mismatch") unless pack["capabilities"] == city["capabilities"]
      validate_coverage_shape!(pack["coverage"], pack["cityID"])
      fail_validation("pack stations must be an array") unless pack["stations"].is_a?(Array)
      return unless pack.key?("destinationNames")

      destinations = pack["destinationNames"]
      fail_validation("destinationNames must be an object") unless destinations.is_a?(Hash)
      fail_validation("destinationNames must have stable code ordering") unless destinations.keys == destinations.keys.sort
      destinations.each do |code, names|
        fail_validation("destination code must be non-empty") if code.empty?
        exact_keys!(names, %w[name nameEn], "destinationNames #{code}")
      end
    end

    def validate_station!(city_id, station, pack_path, network)
      exact_keys!(station, REQUIRED_STATION_KEYS, "#{city_id} station", optional: OPTIONAL_STATION_KEYS)
      fail_validation("#{city_id} stationID is missing") if station["stationID"].to_s.empty?
      fail_validation("#{city_id} stationName is missing") if station["stationName"].to_s.empty?
      fail_validation("#{city_id} stationNameEn must be a string") unless station["stationNameEn"].is_a?(String)
      fail_validation("#{city_id} aliases must be stable and unique") unless station["aliases"].is_a?(Array) && station["aliases"] == station["aliases"].uniq.sort
      fail_validation("#{city_id} schedules must be empty") unless station["schedules"] == []
      fail_validation("#{city_id} stationFacilities must be an array") unless station["stationFacilities"].is_a?(Array)
      fail_validation("#{city_id} externalResources must be an array") unless station["externalResources"].is_a?(Array)
      fail_validation("#{city_id} licensedMedia must be an array") unless station["licensedMedia"].is_a?(Array)
      fail_validation("#{city_id} liveArrivalReferences must be an array") unless station["liveArrivalReferences"].is_a?(Array)
      station["externalResources"].each { |resource| validate_external_resource!(city_id, resource) }
      station["licensedMedia"].each { |media| validate_media!(media, pack_path) }
      station["liveArrivalReferences"].each { |reference| validate_live_reference!(reference) }
      canonical = network.fetch("stations").find { |item| item["id"] == station["stationID"] }
      fail_validation("#{city_id} station is not canonical") unless canonical
      validate_access_points!(city_id, station, canonical)
      line_index = network.fetch("lines").to_h { |line| [line.fetch("id"), line] }
      station["liveArrivalReferences"].each do |reference|
        line = line_index[reference["lineID"]]
        unless line && canonical.fetch("lineIDs").include?(line.fetch("id"))
          fail_validation("live arrival reference is not served by its canonical station")
        end
        expected_reference = reference["lineCode"].to_s.downcase
        unless expected_reference.empty? || line.fetch("routeReference").downcase == expected_reference
          fail_validation("live arrival line code does not match its canonical line")
        end
      end
    end

    # An entrance is only useful if it is near the station it belongs to and in the same
    # coordinate frame as the network. A pack built from unconverted WGS-84 source data would
    # put every entrance several hundred metres away, so the distance is asserted, not assumed.
    ACCESS_POINT_MAX_METRES = 800

    # A pack whose entrances were never converted from WGS-84 to GCJ-02 still passes every
    # per-entrance check, because the whole city is displaced together and each entrance stays
    # within the per-point bound. The uniform displacement is the tell: with the right frame some
    # entrance is essentially on top of its station, and with the wrong one none is close at all.
    ACCESS_POINT_MIN_NEAREST_METRES = 60

    def validate_access_point_frame!(city_id, pack, network)
      positions = network.fetch("stations").to_h { |station| [station.fetch("id"), station] }
      distances = pack.fetch("stations").flat_map do |station|
        canonical = positions[station["stationID"]]
        Array(station["stationAccessPoints"]).map do |point|
          metres_between(
            point["latitude"], point["longitude"],
            canonical.fetch("latitude"), canonical.fetch("longitude")
          )
        end
      end
      return if distances.empty?

      nearest = distances.min
      return if nearest <= ACCESS_POINT_MIN_NEAREST_METRES

      fail_validation(
        "#{city_id} nearest station entrance is #{nearest.round}m from its station — the pack " \
        "looks like it kept its source WGS-84 coordinates instead of converting to GCJ-02"
      )
    end

    def validate_access_points!(city_id, station, canonical)
      points = station["stationAccessPoints"]
      return if points.nil?

      fail_validation("#{city_id} stationAccessPoints must be an array") unless points.is_a?(Array)
      ids = points.map { |point| point["id"] }
      fail_validation("#{city_id} stationAccessPoints must have stable unique ids") unless
        ids == ids.uniq && ids == ids.sort
      points.each do |point|
        exact_keys!(point, REQUIRED_ACCESS_POINT_KEYS, "#{city_id} station access point")
        fail_validation("#{city_id} access point name is missing") if point["name"].to_s.strip.empty?
        fail_validation("#{city_id} access point kind is unsupported") unless
          ACCESS_POINT_KINDS.include?(point["kind"])
        fail_validation("#{city_id} access point source is unsupported") unless
          ACCESS_POINT_SOURCES.include?(point["source"])
        fail_validation("#{city_id} access point isAccessible must be boolean") unless
          [true, false].include?(point["isAccessible"])
        latitude = point["latitude"]
        longitude = point["longitude"]
        unless latitude.is_a?(Numeric) && longitude.is_a?(Numeric)
          fail_validation("#{city_id} access point coordinate must be numeric")
        end
        distance = metres_between(latitude, longitude, canonical.fetch("latitude"), canonical.fetch("longitude"))
        if distance > ACCESS_POINT_MAX_METRES
          fail_validation(
            "#{city_id} access point #{point["name"]} is #{distance.round}m from its station " \
            "(check the coordinate frame)"
          )
        end
      end
    end

    def metres_between(latitude_a, longitude_a, latitude_b, longitude_b)
      mean_latitude = (latitude_a + latitude_b) / 2 * Math::PI / 180
      delta_y = (latitude_a - latitude_b) * Math::PI / 180 * 6_371_000.0
      delta_x = (longitude_a - longitude_b) * Math::PI / 180 * 6_371_000.0 * Math.cos(mean_latitude)
      Math.sqrt(delta_x * delta_x + delta_y * delta_y)
    end

    def validate_external_resource!(city_id, resource)
      exact_keys!(resource, %w[kind title landingPageURL provider], "#{city_id} external resource")
      unless %w[stationLayout timetable accessibility operatorInformation].include?(resource["kind"])
        fail_validation("#{city_id} external resource kind is unsupported")
      end
      fail_validation("#{city_id} external resource title is missing") if resource["title"].to_s.strip.empty?
      fail_validation("#{city_id} external resource provider is missing") if resource["provider"].to_s.strip.empty?
      uri = https_uri(resource["landingPageURL"], "#{city_id} external landingPageURL")
      fail_validation("#{city_id} external landingPageURL must use port 443") unless uri.port == 443
      host = uri.host.downcase
      fail_validation("#{city_id} runtime Commons URLs are forbidden") if COMMONS_RUNTIME_HOSTS.include?(host)
      extension = File.extname(uri.path).downcase
      if FORBIDDEN_EXTERNAL_EXTENSIONS.include?(extension)
        fail_validation("#{city_id} external resources must link to landing pages, not #{extension} files")
      end
      allowed_pages = EXTERNAL_LANDING_PAGES.fetch(city_id)
      unless allowed_pages.include?(resource["landingPageURL"])
        fail_validation("#{city_id} external landing page is not allowlisted")
      end
    end

    def validate_media!(media, pack_path)
      exact_keys!(media, REQUIRED_MEDIA_KEYS, "licensed media")
      fail_validation("licensed media kind must be stationPhoto") unless media["kind"] == "stationPhoto"
      relative_path = media["relativePath"]
      unless safe_relative_path?(relative_path) && relative_path.start_with?("LicensedMedia/")
        fail_validation("licensed media relativePath is unsafe")
      end
      fail_validation("licensed media MIME type is unsupported") unless media["mimeType"] == "image/jpeg"
      fail_validation("licensed media sizeBytes must be positive") unless media["sizeBytes"].is_a?(Integer) && media["sizeBytes"] > 0
      fail_validation("licensed media sha256 must be lowercase hex") unless media["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      fail_validation("unsupported media license #{media["licenseSPDX"]}") unless MEDIA_LICENSES.include?(media["licenseSPDX"])

      source_uri = https_uri(media["sourcePageURL"], "licensed media sourcePageURL")
      unless source_uri.host == "commons.wikimedia.org" && source_uri.path.start_with?("/wiki/File:")
        fail_validation("licensed media sourcePageURL must be a Commons description page")
      end
      license_uri = https_uri(media["licenseURL"], "licensed media licenseURL")
      fail_validation("licensed media licenseURL host is not allowed") unless license_uri.host == "creativecommons.org"

      asset_path = File.join(root, "JustGo", "Resources", relative_path)
      fail_validation("licensed media file is missing") unless File.file?(asset_path)
      fail_validation("licensed media size mismatch") unless media["sizeBytes"] == File.size(asset_path)
      fail_validation("licensed media checksum mismatch") unless media["sha256"] == Digest::SHA256.file(asset_path).hexdigest
    end

    def validate_live_reference!(reference)
      exact_keys!(reference, REQUIRED_LIVE_REFERENCE_KEYS, "live arrival reference")
      fail_validation("live arrival mode is invalid") unless %w[heavyRail lightRail].include?(reference["mode"])
      fail_validation("live arrival stationCode is missing") if reference["stationCode"].to_s.empty?
      fail_validation("live arrival lineID is missing") if reference["lineID"].to_s.empty?
      fail_validation("live arrival lineName is missing") if reference["lineName"].to_s.empty?
      fail_validation("live arrival lineNameEn is missing") if reference["lineNameEn"].to_s.empty?
      fail_validation("live arrival colorHex is invalid") unless reference["colorHex"].to_s.match?(/\A#[0-9A-F]{6}\z/)
      if reference["mode"] == "heavyRail"
        fail_validation("heavy-rail lineCode is missing") if reference["lineCode"].to_s.empty?
      elsif !reference["lineCode"].nil? && reference["lineCode"].to_s.empty?
        fail_validation("light-rail lineCode must be null or non-empty")
      end
    end

    def validate_coverage_shape!(coverage, city_id)
      exact_keys!(coverage, REQUIRED_COVERAGE_KEYS, "#{city_id} coverage")
      network = coverage["networkStations"]
      fail_validation("#{city_id} networkStations must be a non-negative integer") unless network.is_a?(Integer) && network >= 0
      (REQUIRED_COVERAGE_KEYS - ["networkStations"]).each do |key|
        metric = coverage[key]
        exact_keys!(metric, %w[covered total], "#{city_id} coverage #{key}")
        unless metric["covered"].is_a?(Integer) && metric["total"].is_a?(Integer) &&
            metric["covered"].between?(0, metric["total"])
          fail_validation("#{city_id} coverage #{key} is invalid")
        end
      end
    end

    def validate_city_expectations!(city_id, pack, network)
      stations = pack.fetch("stations")
      expected = case city_id
      when "1100"
        {
          "networkStations" => 444,
          "matchedStations" => { "covered" => 444, "total" => 444 },
          "accessibility" => { "covered" => 0, "total" => 444 },
          "staticSchedules" => { "covered" => 0, "total" => 444 },
          "liveArrivals" => { "covered" => 0, "total" => 444 },
          "externalLayouts" => { "covered" => 0, "total" => 444 },
          "licensedMedia" => { "covered" => 0, "total" => 444 },
          "verifiedTransferContexts" => { "covered" => 0, "total" => 444 }
        }
      when "7101"
        # data.taipei covers the Taipei Metro proper; the New Taipei light-rail and branch lines
        # in the same canonical network have no published exit data, so coverage is partial and
        # the exact split is pinned here to catch a silent regression in either direction.
        exits = stations.sum { |station| Array(station["stationAccessPoints"]).length }
        fail_validation("Taipei pack lost station exits (#{exits})") unless exits == 388
        unless stations.all? { |station| !Array(station["stationAccessPoints"]).empty? }
          fail_validation("Taipei pack has a station with no exits")
        end
        {
          "networkStations" => 151,
          "matchedStations" => { "covered" => 118, "total" => 151 },
          "accessibility" => { "covered" => 118, "total" => 151 },
          "staticSchedules" => { "covered" => 0, "total" => 151 },
          "liveArrivals" => { "covered" => 0, "total" => 151 },
          "externalLayouts" => { "covered" => 0, "total" => 151 },
          "licensedMedia" => { "covered" => 0, "total" => 151 },
          "verifiedTransferContexts" => { "covered" => 0, "total" => 151 }
        }
      else
        missing = network.fetch("stations").reject do |canonical|
          stations.any? { |station| station["stationID"] == canonical["id"] }
        end
        fail_validation("Hong Kong pack must cover every canonical station") unless missing.empty?
        renamed = stations.find { |station| station["stationNameEn"] == "Hoi Wong Road" }
        unless renamed && renamed["stationName"] == "海皇路" &&
            renamed["aliases"].include?("Tuen Mun Swimming Pool") &&
            renamed["aliases"].include?("屯門泳池")
          fail_validation("Hong Kong Hoi Wong Road rename or former-name aliases are missing")
        end
        racecourse = stations.find { |station| station["stationNameEn"] == "Racecourse" }
        unless racecourse && racecourse["stationID"] == OSSCityPackPipeline::RACECOURSE_REFERENCE.fetch("canonicalStationID") &&
            racecourse["liveArrivalReferences"].any? do |reference|
              reference["mode"] == "heavyRail" && reference["lineCode"] == "EAL" &&
                reference["stationCode"] == "RAC"
            end
          fail_validation("Hong Kong Racecourse canonical/live reference is missing")
        end
        {
          "networkStations" => 162,
          "matchedStations" => { "covered" => 162, "total" => 162 },
          "accessibility" => { "covered" => 98, "total" => 162 },
          "staticSchedules" => { "covered" => 0, "total" => 162 },
          "liveArrivals" => { "covered" => 162, "total" => 162 },
          "externalLayouts" => { "covered" => 0, "total" => 162 },
          "licensedMedia" => { "covered" => 0, "total" => 162 },
          "verifiedTransferContexts" => { "covered" => 0, "total" => 162 }
        }
      end
      fail_validation("#{city_id} exact coverage metrics changed") unless pack["coverage"] == expected
    end

    def coverage_for(network_count, stations)
      metric = ->(count) { { "covered" => count, "total" => network_count } }
      {
        "networkStations" => network_count,
        "matchedStations" => metric.call(stations.length),
        "accessibility" => metric.call(stations.count { |station| !station["accessibility"].nil? }),
        "staticSchedules" => metric.call(stations.count { |station| !station.fetch("schedules").empty? }),
        "liveArrivals" => metric.call(stations.count { |station| !station.fetch("liveArrivalReferences").empty? }),
        "externalLayouts" => metric.call(0),
        "licensedMedia" => metric.call(stations.count { |station| !station.fetch("licensedMedia").empty? }),
        "verifiedTransferContexts" => metric.call(0)
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

    def network_station_count(city_id)
      path = File.join(root, "JustGo", "Resources", "MetroNetworks", "#{city_id}.json")
      File.file?(path) ? load_json(path).fetch("stations").length : 0
    end

    def load_network(city_id)
      load_json(File.join(root, "JustGo", "Resources", "MetroNetworks", "#{city_id}.json"))
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
