#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
OUTPUT_PATH = File.join(DATA_PACKS_DIR, "manifest.json")
PRIMARY_HOST = nil

def city_pack_entry(city_id)
  pack_dirs = Dir.glob(File.join(DATA_PACKS_DIR, "packs", city_id, "*"))
    .select { |path| File.directory?(path) }
    .sort
  latest_dir = pack_dirs.last
  return nil unless latest_dir

  pack_path = File.join(latest_dir, "city_pack.json")
  return nil unless File.exist?(pack_path)

  data = File.binread(pack_path)
  pack = JSON.parse(data)
  version = File.basename(latest_dir)
  capabilities = pack.fetch("capabilities")
  {
    "cityID" => city_id,
    "version" => version,
    "sizeBytes" => data.bytesize,
    "sha256" => Digest::SHA256.hexdigest(data),
    "downloadURL" => "packs/#{city_id}/#{version}/city_pack.json",
    "sourceURLs" => pack.fetch("sourceURLs", []),
    "capabilities" => capabilities
  }
end

existing_ids = if File.exist?(OUTPUT_PATH)
  JSON.parse(File.read(OUTPUT_PATH)).fetch("cities", []).map { |city| city.fetch("cityID") }
else
  []
end
pack_ids = Dir.glob(File.join(DATA_PACKS_DIR, "packs", "*")).select { |path| File.directory?(path) }.map { |path| File.basename(path) }
city_ids = existing_ids + (pack_ids - existing_ids).sort
manifest = {
  "schemaVersion" => 1,
  "generatedAt" => Time.now.utc.iso8601,
  "primaryHost" => PRIMARY_HOST,
  "cities" => city_ids.map do |city_id|
    city_pack_entry(city_id) || {
      "cityID" => city_id,
      "version" => "source-pending",
      "sizeBytes" => 0,
      "sha256" => nil,
      "downloadURL" => nil,
      "sourceURLs" => [],
      "capabilities" => {
        "accessibility" => "source_pending",
        "schedules" => "source_pending",
        "liveArrivals" => "source_pending",
        "stationMaps" => "source_pending"
      }
    }
  end
}

Dir.mkdir(DATA_PACKS_DIR) unless Dir.exist?(DATA_PACKS_DIR)
File.write(OUTPUT_PATH, "#{JSON.pretty_generate(manifest)}\n")
puts "Wrote #{OUTPUT_PATH} (#{manifest["cities"].length} cities)"
