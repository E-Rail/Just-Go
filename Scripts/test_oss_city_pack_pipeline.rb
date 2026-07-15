#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require_relative "lib/oss_city_pack_pipeline"
require_relative "lib/oss_data_validators"

class OSSCityPackPipelineTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GENERATED_FILES = [
    "DataPacks/manifest.json",
    "DataPacks/rights_inventory.json",
    "DataPacks/sources/8100/metadata.json",
    "THIRD_PARTY_NOTICES.md",
    "JustGo/Resources/BundledCityPacks/1100.json",
    "JustGo/Resources/BundledCityPacks/8100.json"
  ].freeze

  def test_exact_schema_and_generated_counts
    manifest = json("DataPacks/manifest.json")
    beijing = json("JustGo/Resources/BundledCityPacks/1100.json")
    hong_kong = json("JustGo/Resources/BundledCityPacks/8100.json")
    sources = json("DataPacks/sources/8100/metadata.json")
    rights = json("DataPacks/rights_inventory.json")

    assert_equal 2, manifest.fetch("schemaVersion")
    assert_equal 2, sources.fetch("schemaVersion")
    assert_equal 2, rights.fetch("schemaVersion")
    assert_equal OSSCityPackPipeline::DATA_GOV_HK_LICENSE.to_h, sources.fetch("dataLicense")
    assert_equal OSSCityPackPipeline::REALTIME_APIS, sources.fetch("realtimeAPIs")
    assert_equal [OSSCityPackPipeline::RACECOURSE_REFERENCE], sources.fetch("explicitCanonicalReferences")
    assert_equal [OSSCityPackPipeline::DATA_GOV_HK_LICENSE.to_h], rights.fetch("dataLicenses")
    assert_equal 58, manifest.fetch("cities").length
    bundled_city_ids = manifest.fetch("cities").map do |city|
      city["cityID"] if city["bundledResource"]
    end.compact
    assert_equal %w[1100 8100], bundled_city_ids
    assert manifest.fetch("cities").all? { |city| city["downloadURL"].nil? }
    assert_equal 46, manifest.fetch("cities").count { |city| city.dig("coverage", "networkStations").positive? }
    assert_equal 12, manifest.fetch("cities").count { |city| city.dig("coverage", "networkStations").zero? }

    macau = manifest.fetch("cities").find { |city| city.fetch("cityID") == "8200" }
    assert_equal "source-pending", macau.fetch("version")
    assert_equal ["macau-official-landing-link", "osm-metro-networks"], macau.fetch("rightsIDs")
    assert_equal "https://www.mlm.com.mo/en/", macau.fetch("externalResources").first.fetch("landingPageURL")

    assert_equal 444, beijing.fetch("stations").length
    assert_equal 162, hong_kong.fetch("stations").length
    assert_equal 98, hong_kong.fetch("stations").count { |station| station["accessibility"] }
    assert_equal 2_047, hong_kong.fetch("stations").sum { |station| station.fetch("stationFacilities").length }
    assert_equal 98, hong_kong.fetch("destinationNames").length

    references = hong_kong.fetch("stations").flat_map { |station| station.fetch("liveArrivalReferences") }
    assert_equal 121, references.count { |reference| reference["mode"] == "heavyRail" }
    assert_equal 205, references.count { |reference| reference["mode"] == "lightRail" }
    assert_equal 326, references.length
    assert_equal({ "covered" => 0, "total" => 444 }, beijing.dig("coverage", "externalLayouts"))

    barrier = sources.fetch("resources").find do |resource|
      resource["fileName"] == "barrier_free_facilities.csv"
    end
    assert_equal 99, barrier.fetch("stationGroupCount")
    assert_equal(
      {
        "networkStations" => 162,
        "matchedStations" => { "covered" => 162, "total" => 162 },
        "accessibility" => { "covered" => 98, "total" => 162 },
        "staticSchedules" => { "covered" => 0, "total" => 162 },
        "liveArrivals" => { "covered" => 162, "total" => 162 },
        "externalLayouts" => { "covered" => 98, "total" => 162 },
        "licensedMedia" => { "covered" => 1, "total" => 162 },
        "verifiedTransferContexts" => { "covered" => 0, "total" => 162 }
      },
      hong_kong.fetch("coverage")
    )
  end

  def test_racecourse_reference_and_hoi_wong_road_rename_are_explicit
    pack = json("JustGo/Resources/BundledCityPacks/8100.json")
    racecourse = pack.fetch("stations").find { |station| station["stationNameEn"] == "Racecourse" }
    refute_nil racecourse
    assert_equal OSSCityPackPipeline::RACECOURSE_REFERENCE.fetch("canonicalStationID"), racecourse.fetch("stationID")
    assert racecourse.fetch("liveArrivalReferences").any? { |reference|
      reference["mode"] == "heavyRail" && reference["lineCode"] == "EAL" &&
        reference["stationCode"] == "RAC"
    }

    renamed = pack.fetch("stations").find do |station|
      station["stationNameEn"] == "Hoi Wong Road"
    end
    refute_nil renamed
    assert_equal "海皇路", renamed.fetch("stationName")
    assert_includes renamed.fetch("aliases"), "Tuen Mun Swimming Pool"
    assert_includes renamed.fetch("aliases"), "屯門泳池"
    refute_includes renamed.fetch("aliases"), "Hoi Wong Road"
    refute_includes renamed.fetch("aliases"), "海皇路"
  end

  def test_media_metadata_matches_shared_normalized_files
    declarations = %w[1100 8100].flat_map do |city_id|
      json("JustGo/Resources/BundledCityPacks/#{city_id}.json").fetch("stations")
        .flat_map { |station| station.fetch("licensedMedia") }
    end
    assert_equal 2, declarations.length
    declarations.each do |media|
      path = File.join(ROOT, "JustGo", "Resources", media.fetch("relativePath"))
      assert_equal File.size(path), media.fetch("sizeBytes")
      assert_equal Digest::SHA256.file(path).hexdigest, media.fetch("sha256")
    end
  end

  def test_builder_is_byte_for_byte_deterministic
    builder = OSSCityPackPipeline::Builder.new(root: ROOT)
    builder.run
    first = generated_digests
    builder.run
    assert_equal first, generated_digests
  end

  def test_validators_accept_generated_baseline
    assert OSSDataValidators::RightsValidator.new(root: ROOT).validate!
    assert OSSDataValidators::CityPackValidator.new(root: ROOT).validate!
    %w[
      validate_data_rights.rb validate_runtime_data_policy.rb validate_city_packs.rb validate_schedule_colors.rb
      validate_localizations.rb validate_metro_networks.rb validate_indoor_maps.rb
    ].each do |script|
      assert File.executable?(File.join(ROOT, "Scripts", script)), "#{script} must be executable"
    end
  end

  private

  def json(relative_path)
    JSON.parse(File.read(File.join(ROOT, relative_path), encoding: "UTF-8"))
  end

  def generated_digests
    GENERATED_FILES.to_h do |relative_path|
      [relative_path, Digest::SHA256.file(File.join(ROOT, relative_path)).hexdigest]
    end
  end
end
