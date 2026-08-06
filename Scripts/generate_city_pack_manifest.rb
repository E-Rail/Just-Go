#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/oss_city_pack_pipeline"

options = {
  snapshot_dir: "/private/tmp",
  refresh_sources: false
}
OptionParser.new do |parser|
  parser.banner = "Usage: generate_city_pack_manifest.rb [options]"
  parser.on("--snapshot-dir DIR", "Directory containing the four just-go-*.csv snapshots") do |value|
    options[:snapshot_dir] = value
  end
  parser.on("--refresh-sources", "Replace vendored CSVs from --snapshot-dir") do
    options[:refresh_sources] = true
  end
end.parse!

builder = OSSCityPackPipeline::Builder.new(snapshot_dir: options.fetch(:snapshot_dir))
summary = builder.run(refresh_sources: options.fetch(:refresh_sources))
puts "OSS city-pack build complete: " \
  "catalog=#{summary.fetch(:city_count)} " \
  "bundled=#{summary.fetch(:bundled_city_count)} " \
  "beijing=#{summary.fetch(:beijing_station_count)} " \
  "hong_kong=#{summary.fetch(:hong_kong_station_count)} " \
  "accessibility_source_groups=#{summary.fetch(:hong_kong_accessibility_source_groups)}"
