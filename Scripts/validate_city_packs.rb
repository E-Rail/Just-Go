#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
MANIFEST_PATH = File.join(DATA_PACKS_DIR, "manifest.json")

def fail_with(message)
  warn "city-pack validation failed: #{message}"
  exit 1
end

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => error
  fail_with("#{path} is not valid JSON: #{error.message}")
end

manifest = load_json(MANIFEST_PATH)
fail_with("schemaVersion must be 1") unless manifest["schemaVersion"] == 1

cities = manifest["cities"]
fail_with("cities must be a non-empty array") unless cities.is_a?(Array) && !cities.empty?

pack_count = 0
cities.each do |city|
  city_id = city["cityID"]
  fail_with("cityID is missing") if city_id.to_s.empty?

  download_url = city["downloadURL"]
  next if download_url.nil?

  fail_with("#{city_id} downloadURL must be relative") if download_url.match?(%r{\Ahttps?://}i)

  pack_path = File.expand_path(download_url, DATA_PACKS_DIR)
  fail_with("#{city_id} downloadURL escapes DataPacks") unless pack_path.start_with?("#{DATA_PACKS_DIR}/")
  fail_with("#{city_id} pack is missing at #{download_url}") unless File.file?(pack_path)

  data = File.binread(pack_path)
  expected_size = city["sizeBytes"]
  fail_with("#{city_id} sizeBytes mismatch") if expected_size && expected_size != data.bytesize

  expected_sha = city["sha256"]
  actual_sha = Digest::SHA256.hexdigest(data)
  fail_with("#{city_id} sha256 mismatch") if expected_sha.to_s.empty? || expected_sha != actual_sha

  pack = load_json(pack_path)
  fail_with("#{city_id} city_pack cityID mismatch") unless pack["cityID"] == city_id
  fail_with("#{city_id} city_pack version mismatch") unless pack["version"] == city["version"]
  fail_with("#{city_id} city_pack stations must be an array") unless pack["stations"].is_a?(Array)
  pack["stations"].each do |station|
    Array(station["stationMaps"]).each do |station_map|
      asset_url = station_map["assetURL"].to_s
      fail_with("#{city_id} station map assetURL is missing") if asset_url.empty?
      fail_with("#{city_id} station map must be a relative asset path") if asset_url.match?(%r{\Ahttps?://}i)
      fail_with("#{city_id} station map hotlinks official source") if asset_url.include?("bjsubway.com") || asset_url.include?("mtr.bj.cn")

      asset_path = File.expand_path(asset_url, File.dirname(pack_path))
      fail_with("#{city_id} station map escapes pack directory") unless asset_path.start_with?("#{File.dirname(pack_path)}/")
      fail_with("#{city_id} station map is missing at #{asset_url}") unless File.file?(asset_path)
    end
  end

  pack_count += 1
end

puts "city-pack validation ok: cities=#{cities.length} packs=#{pack_count}"
