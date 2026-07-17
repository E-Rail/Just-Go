#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/official_transit_resource_catalog"

class OfficialTransitResourceCatalogBuilderTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
  end

  def test_catalog_has_exact_reviewed_city_and_hong_kong_counts
    catalog = OfficialTransitResourceCatalogBuilder::Builder.new(root: @root).build
    beijing = catalog.fetch("cities").find { |city| city.fetch("cityID") == "1100" }
    hong_kong = catalog.fetch("cities").find { |city| city.fetch("cityID") == "8100" }
    resources = hong_kong.fetch("resources") + hong_kong.fetch("stationResources").flat_map { |station| station.fetch("resources") }

    assert_equal 58, catalog.fetch("cities").length
    assert_equal 444, beijing.fetch("stationResources").length
    assert_equal 416, beijing.fetch("stationResources").count { |station|
      station.fetch("resources").any? {
        |resource| resource.fetch("targetURL").include?("/station/siteinfo.html?loc=")
      }
    }
    assert_equal 418, beijing.fetch("stationResources").count {
      |station| station.fetch("stationInformationStatus") == "exactPage"
    }
    assert_equal 18, beijing.fetch("stationResources").count {
      |station| station.fetch("stationInformationStatus") == "officialContextOnly"
    }
    assert_equal 3, beijing.fetch("stationResources").count {
      |station| station.fetch("stationInformationStatus") == "notOpenForPassengerService"
    }
    assert_equal 5, beijing.fetch("stationResources").count {
      |station| station.fetch("stationInformationStatus") == "noCurrentPassengerService"
    }
    assert_equal 197, resources.select { |resource| %w[systemMap locationMap stationLayout].include?(resource.fetch("kind")) }.map { |resource| resource.fetch("targetURL") }.uniq.length
    assert_equal 14, resources.select { |resource| resource.fetch("kind") == "streetMap" }.map { |resource| resource.fetch("targetURL") }.uniq.length
  end

  def test_builder_rejects_unreviewed_or_reordered_city_records
    builder = OfficialTransitResourceCatalogBuilder::Builder.new(root: @root)
    cities = Marshal.load(Marshal.dump(builder.reviewed_cities)).rotate
    assert_raises(OfficialTransitResourceCatalogBuilder::BuildError) { builder.build(cities: cities) }
  end

  def test_builder_rejects_undeclared_domains
    builder = OfficialTransitResourceCatalogBuilder::Builder.new(root: @root)
    cities = Marshal.load(Marshal.dump(builder.reviewed_cities))
    city = cities.find { |item| !item.fetch("resources").empty? }
    city.fetch("resources").first["targetURL"] = "https://example.com/transit"
    assert_raises(OfficialTransitResourceCatalogBuilder::BuildError) { builder.build(cities: cities) }
  end

  def test_builder_rejects_redirect_and_template_urls
    builder = OfficialTransitResourceCatalogBuilder::Builder.new(root: @root)
    cities = Marshal.load(Marshal.dump(builder.reviewed_cities))
    city = cities.find { |item| !item.fetch("resources").empty? }
    resource = city.fetch("resources").first
    host = URI(resource.fetch("targetURL")).host

    resource["targetURL"] = "https://#{host}/open?url=https%3A%2F%2Fexample.com"
    assert_raises(OfficialTransitResourceCatalogBuilder::BuildError) { builder.build(cities: cities) }

    resource["targetURL"] = "https://#{host}/station/%7BstationID%7D"
    assert_raises(OfficialTransitResourceCatalogBuilder::BuildError) { builder.build(cities: cities) }
  end
end
