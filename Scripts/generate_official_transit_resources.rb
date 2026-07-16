#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/official_transit_resource_catalog"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(ROOT, "DataPacks", "official_transit_resources.json")
catalog = OfficialTransitResourceCatalogBuilder::Builder.new(root: ROOT).build
File.write(OUTPUT, JSON.pretty_generate(catalog) + "\n")

coverage = catalog.fetch("cities").map { |city| city.fetch("coverage") }
puts "Official resources: cities=#{catalog.fetch('cities').length} links=#{coverage.sum { |item| item.fetch('totalLinks') }} maps=#{coverage.sum { |item| item.fetch('maps') }} travel=#{coverage.sum { |item| item.fetch('travel') }} accessibility=#{coverage.sum { |item| item.fetch('accessibility') }} help=#{coverage.sum { |item| item.fetch('help') }}"
