#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/oss_data_validators"

ROOT = File.expand_path("..", __dir__)
PACK_PATTERN = File.join(ROOT, "Just-Go", "Resources", "BundledCityPacks", "*.json")
EXPECTED_PACK_IDS = OSSDataValidators::BUNDLED_CITY_IDS

def fail_with(message)
  warn "schedule-color validation failed: #{message}"
  exit 1
end

legacy_files = Dir.glob(File.join(ROOT, "DataPacks", "packs", "**", "*"))
  .select { |path| File.file?(path) }
fail_with("legacy DataPacks/packs content is forbidden") unless legacy_files.empty?

pack_paths = Dir.glob(PACK_PATTERN).sort
pack_ids = []
schedule_count = 0

pack_paths.each do |pack_path|
  pack = JSON.parse(File.read(pack_path, encoding: "UTF-8"))
  city_id = pack.fetch("cityID")
  pack_ids << city_id
  schedules = pack.fetch("stations").flat_map { |station| station.fetch("schedules") }
  schedule_count += schedules.length
end

unless pack_ids.sort == EXPECTED_PACK_IDS.sort
  fail_with("expected exactly the reviewed #{EXPECTED_PACK_IDS.join(", ")} baselines")
end
unless schedule_count.zero?
  fail_with("static schedules require a separately reviewed reusable source; found #{schedule_count} rows")
end

puts "schedule-color validation ok: packs=#{pack_ids.length} static_schedules=#{schedule_count}"
