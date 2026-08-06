#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/oss_data_validators"

begin
  OSSDataValidators::CityPackValidator.new.validate!
  manifest = JSON.parse(File.read(File.expand_path("../DataPacks/manifest.json", __dir__)))
  bundled = manifest.fetch("cities").count { |city| !city["bundledResource"].nil? }
  puts "city-pack validation ok: schema=2 cities=#{manifest.fetch("cities").length} bundled=#{bundled}"
rescue OSSDataValidators::ValidationError => error
  warn "city-pack validation failed: #{error.message}"
  exit 1
end
