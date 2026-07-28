#!/usr/bin/env ruby
# frozen_string_literal: true

# Validates the StationInfoAPI developer contract: the wire schema, the source registry, and the
# generated directory, plus their mutual consistency. Run in CI alongside the other validators.

require "json"

ROOT = File.expand_path("..", __dir__)
API_DIR = File.join(ROOT, "StationInfoAPI")
SCHEMA_PATH = File.join(API_DIR, "schema", "station-information.schema.json")
SOURCES_PATH = File.join(API_DIR, "sources", "sources.json")
DIRECTORY_PATH = File.join(API_DIR, "directory", "directory.json")
API_DOC_PATH = File.join(API_DIR, "API.md")
README_PATH = File.join(API_DIR, "README.md")
RIGHTS_PATH = File.join(ROOT, "DataPacks", "rights_inventory.json")

def fail_validation(message)
  warn "station info API validation failed: #{message}"
  exit 1
end

def load_json(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  fail_validation("missing file: #{path.delete_prefix("#{ROOT}/")}")
rescue JSON::ParserError => error
  fail_validation("#{path.delete_prefix("#{ROOT}/")} is not valid JSON: #{error.message}")
end

schema = load_json(SCHEMA_PATH)
sources_doc = load_json(SOURCES_PATH)
directory = load_json(DIRECTORY_PATH)

# ---- Schema -------------------------------------------------------------------------------
unless schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
  fail_validation("schema must declare draft 2020-12")
end
defs = schema["$defs"]
fail_validation("schema is missing $defs") unless defs.is_a?(Hash)
%w[snapshot freshness line service exit facilityGroup facility envelope].each do |name|
  fail_validation("schema is missing $defs.#{name}") unless defs.key?(name)
end
snapshot_props = defs.dig("snapshot", "properties") || {}
%w[stationID stationName source freshness lines exits facilityGroups].each do |field|
  fail_validation("schema snapshot is missing field #{field}") unless snapshot_props.key?(field)
end
unless defs.dig("snapshot", "properties", "source", "type") == "string"
  fail_validation("schema `source` must stay an open string so adding a city is additive")
end
unless defs.dig("envelope", "properties", "schemaVersion", "const") == 2
  fail_validation("schema envelope must pin schemaVersion 2 (matches the on-device cache)")
end

# ---- Source registry ----------------------------------------------------------------------
supported_licenses = load_json(RIGHTS_PATH).fetch("supportedLicenses")
sources = sources_doc["sources"]
fail_validation("sources.json has no `sources` object") unless sources.is_a?(Hash) && !sources.empty?

VALID_STATUS = %w[stable preview].freeze
VALID_ACCESS = %w[onDeviceFetch bundledDataset].freeze
VALID_POPULATES = %w[lines exits facilityGroups liveArrivals].freeze

stable_sources = []
sources.each do |id, source|
  %w[cityID provider attribution license redistributable status populates directoryKey access].each do |key|
    fail_validation("source #{id} is missing #{key}") unless source.key?(key)
  end
  fail_validation("source #{id} has unknown status #{source['status']}") unless VALID_STATUS.include?(source["status"])
  unless [true, false].include?(source["redistributable"])
    fail_validation("source #{id} redistributable must be a boolean")
  end
  unless supported_licenses.include?(source["license"])
    fail_validation("source #{id} license #{source['license']} is not in rights_inventory supportedLicenses")
  end
  populates = source["populates"]
  unless populates.is_a?(Array) && !populates.empty? && (populates - VALID_POPULATES).empty?
    fail_validation("source #{id} populates is invalid: #{populates.inspect}")
  end
  access_kind = source.dig("access", "kind")
  fail_validation("source #{id} has unknown access.kind #{access_kind}") unless VALID_ACCESS.include?(access_kind)
  # A non-redistributable source must be fetched on-device, never bundled and re-served.
  if source["redistributable"] == false && access_kind != "onDeviceFetch"
    fail_validation("source #{id} is link-only but not marked onDeviceFetch")
  end
  stable_sources << id if source["status"] == "stable"
end
stable_sources.sort!

# ---- Directory ----------------------------------------------------------------------------
%w[schemaVersion sources stationCount stations].each do |key|
  fail_validation("directory.json is missing #{key}") unless directory.key?(key)
end
stations = directory["stations"]
fail_validation("directory stations must be an object") unless stations.is_a?(Hash)

station_ids = stations.keys
unless station_ids == station_ids.sort
  fail_validation("directory stations must be sorted by station ID")
end
unless directory["stationCount"] == station_ids.length
  fail_validation("directory stationCount #{directory['stationCount']} != #{station_ids.length} entries")
end

used_sources = []
stations.each do |station_id, entry|
  fail_validation("directory entry #{station_id} has no name") if entry["name"].to_s.strip.empty?
  entry_sources = entry["sources"]
  fail_validation("directory entry #{station_id} has no sources") unless entry_sources.is_a?(Hash) && !entry_sources.empty?
  entry_sources.each_key do |source_id|
    unless sources.key?(source_id)
      fail_validation("directory entry #{station_id} references unknown source #{source_id}")
    end
    if sources.dig(source_id, "status") != "stable"
      fail_validation("directory entry #{station_id} references non-stable source #{source_id}")
    end
    used_sources << source_id
  end
end
used_sources = used_sources.uniq.sort

unless directory["sources"] == used_sources
  fail_validation("directory `sources` list #{directory['sources'].inspect} != sources actually used #{used_sources.inspect}")
end

# Every stable source must appear in the directory, and every directory source must be stable —
# a stable source with no catalog, or a preview source leaking into the directory, is a defect.
if used_sources != stable_sources
  fail_validation("stable sources #{stable_sources.inspect} do not match directory sources #{used_sources.inspect}")
end

# ---- DataPacks <-> API agreement ----------------------------------------------------------
# Every stable source must trace back to a reviewed DataPacks catalog and a rights-inventory
# grant, and the directory must carry exactly that catalog's stations. This is what keeps the
# published API and the internal DataPacks from drifting apart: add a stable source without a
# catalog, or let a catalog and the directory diverge by even one station, and this fails.
STABLE_CATALOGS = {
  "beijingSubwayOnline" => {
    catalog: "DataPacks/sources/official-resources/beijing_station_information.json",
    rightsID: "beijing-official-landing-links"
  },
  "shanghaiMetroOnline" => {
    catalog: "DataPacks/sources/official-resources/shanghai_station_information.json",
    rightsID: "shanghai-official-landing-links"
  },
  "guangzhouMetroOnline" => {
    catalog: "DataPacks/sources/official-resources/guangzhou_station_information.json",
    rightsID: "guangzhou-official-station-references"
  },
  "hangzhouMetroOnline" => {
    catalog: "DataPacks/sources/official-resources/hangzhou_station_information.json",
    rightsID: "hangzhou-official-station-references"
  },
  "hongKongGovernment" => {
    catalog: "DataPacks/sources/official-resources/hong_kong_station_bindings.json",
    rightsID: "data-gov-hk-mtr"
  }
}.freeze

unless STABLE_CATALOGS.keys.sort == stable_sources
  fail_validation("stable sources #{stable_sources.inspect} have no DataPacks catalog mapping " \
    "(#{STABLE_CATALOGS.keys.sort.inspect}); every stable source needs a reviewed catalog")
end

rights_ids = load_json(RIGHTS_PATH).fetch("rights").map { |right| right.fetch("id") }
STABLE_CATALOGS.each do |source_id, binding|
  catalog = load_json(File.join(ROOT, binding[:catalog]))
  catalog_ids = catalog.fetch("stations").map { |station| station.fetch("stationID") }.sort
  directory_ids = stations.select { |_id, entry| entry["sources"].key?(source_id) }.keys.sort
  unless catalog_ids == directory_ids
    fail_validation("#{source_id}: directory carries #{directory_ids.length} stations but its " \
      "DataPacks catalog has #{catalog_ids.length}; they must be the same stations")
  end
  unless rights_ids.include?(binding[:rightsID])
    fail_validation("#{source_id}: rights grant #{binding[:rightsID]} is missing from rights_inventory")
  end
end

# ---- Drift --------------------------------------------------------------------------------
unless system("ruby", File.join(ROOT, "Scripts", "generate_station_info_api.rb"), "--check")
  fail_validation("directory.json is stale relative to the catalogs; regenerate it")
end

# ---- Docs present and self-consistent -----------------------------------------------------
fail_validation("API.md is missing") unless File.file?(API_DOC_PATH)
fail_validation("README.md is missing") unless File.file?(README_PATH)
readme = File.read(README_PATH)
%w[schema/station-information.schema.json sources/sources.json directory/directory.json].each do |ref|
  fail_validation("README.md does not reference #{ref}") unless readme.include?(ref)
end
unless File.read(API_DOC_PATH).include?("LicenseRef-External-Link-Only")
  fail_validation("API.md must state the link-only boundary")
end

puts "station info API OK: #{stable_sources.length} stable sources, #{station_ids.length} stations, schema draft 2020-12."
