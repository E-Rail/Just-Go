#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "lib/oss_data_validators"

class OSSDataValidatorsTest < Minitest::Test
  SOURCE_ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("justgo-oss-validator")
    copy_fixture
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_rejects_undeclared_binary
    path = File.join(@root, "JustGo", "Resources", "LicensedMedia", "undeclared.jpg")
    File.binwrite(path, "not declared")

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/missing rights declarations|undeclared binary/, error.message)
  end

  def test_rejects_undeclared_json
    write_json("DataPacks/sources/8100/rogue.json", { "copied" => true })

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/missing rights declarations/, error.message)
  end

  def test_rejects_undeclared_csv
    path = File.join(@root, "DataPacks", "sources", "8100", "rogue.csv")
    File.write(path, "station,name\n1,Unknown\n")

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/missing rights declarations/, error.message)
  end

  def test_rejects_unsupported_license
    inventory = read_json("DataPacks/rights_inventory.json")
    inventory.fetch("rights").first["licenseSPDX"] = "GPL-3.0-only"
    write_json("DataPacks/rights_inventory.json", inventory)

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/unsupported license/, error.message)
  end

  def test_rejects_direct_pdf_external_link
    mutate_pack("8100") do |pack|
      station = pack.fetch("stations").find { |item| !item.fetch("externalResources").empty? }
      station.fetch("externalResources").first["landingPageURL"] =
        "https://www.mtr.com.hk/archive/en/services/layouts/cen.pdf"
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/landing pages, not \.pdf files/, error.message)
  end

  def test_rejects_direct_image_external_link
    mutate_pack("8100") do |pack|
      station = pack.fetch("stations").find { |item| !item.fetch("externalResources").empty? }
      station.fetch("externalResources").first["landingPageURL"] =
        "https://www.mtr.com.hk/archive/en/services/layouts/cen.jpg"
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/landing pages, not \.jpg files/, error.message)
  end

  def test_rejects_non_https_external_link
    mutate_pack("8100") do |pack|
      station = pack.fetch("stations").find { |item| !item.fetch("externalResources").empty? }
      station.fetch("externalResources").first["landingPageURL"] =
        "http://www.mtr.com.hk/en/customer/services/system_map.html"
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/must use HTTPS/, error.message)
  end

  def test_rejects_unallowlisted_external_host
    mutate_pack("8100") do |pack|
      station = pack.fetch("stations").find { |item| !item.fetch("externalResources").empty? }
      station.fetch("externalResources").first["landingPageURL"] = "https://example.com/layout"
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/not allowlisted/, error.message)
  end

  def test_rejects_runtime_commons_url
    mutate_pack("8100") do |pack|
      station = pack.fetch("stations").find { |item| !item.fetch("externalResources").empty? }
      station.fetch("externalResources").first["landingPageURL"] =
        "https://commons.wikimedia.org/wiki/File:Central_station_in_Hong_Kong.jpg"
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/runtime Commons URLs are forbidden/, error.message)
  end

  def test_rejects_inconsistent_coverage_even_when_manifest_matches
    mutate_pack("8100", sync_coverage: true) do |pack|
      pack.fetch("coverage").fetch("liveArrivals")["covered"] = 160
    end

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/pack coverage is inconsistent/, error.message)
  end

  def test_rejects_legacy_data_packs_tree
    path = File.join(@root, "DataPacks", "packs", "8100", "city_pack.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}\n")

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(%r{DataPacks/packs content is forbidden}, error.message)
  end

  def test_history_check_ignores_parent_data_packs_trees
    initialize_fixture_repository

    assert rights_validator.validate_history!
  end

  def test_history_check_rejects_removed_legacy_pack_objects
    initialize_fixture_repository
    path = File.join(@root, "DataPacks", "packs", "legacy.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}\n")
    git("add", "DataPacks/packs/legacy.json")
    git("commit", "-m", "add legacy pack")
    FileUtils.rm_rf(File.join(@root, "DataPacks", "packs"))
    git("add", "-A")
    git("commit", "-m", "remove legacy pack")

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate_history! }
    assert_match(/Git history still contains DataPacks\/packs objects/, error.message)
  end

  def test_rejects_incorrect_rights_assignment
    inventory = read_json("DataPacks/rights_inventory.json")
    entry = inventory.fetch("files").find do |item|
      item["path"] == "DataPacks/sources/8100/mtr_lines_and_stations.csv"
    end
    entry["rightsIDs"] = ["justgo-generated-catalog"]
    write_json("DataPacks/rights_inventory.json", inventory)

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/incorrect rights assignment/, error.message)
  end

  def test_rejects_media_rights_evidence_mismatch
    inventory = read_json("DataPacks/rights_inventory.json")
    right = inventory.fetch("rights").find { |item| item["id"] == "media-central-qqhhss" }
    right["bundledSHA256"] = "0" * 64
    write_json("DataPacks/rights_inventory.json", inventory)

    error = assert_raises(OSSDataValidators::ValidationError) { rights_validator.validate! }
    assert_match(/rights evidence checksum mismatch/, error.message)
  end

  def test_rejects_missing_declared_media
    FileUtils.rm(File.join(@root, "JustGo", "Resources", "LicensedMedia", "hong-kong-central.jpg"))

    error = assert_raises(OSSDataValidators::ValidationError) { city_validator.validate! }
    assert_match(/licensed media file is missing|structured\/bundled files missing rights declarations/, error.message)
  end

  private

  def copy_fixture
    FileUtils.cp_r(File.join(SOURCE_ROOT, "DataPacks"), @root)
    resources = File.join(@root, "JustGo", "Resources")
    FileUtils.mkdir_p(resources)
    FileUtils.cp_r(File.join(SOURCE_ROOT, "JustGo", "Resources", "BundledCityPacks"), resources)
    FileUtils.cp_r(File.join(SOURCE_ROOT, "JustGo", "Resources", "LicensedMedia"), resources)
    FileUtils.cp_r(File.join(SOURCE_ROOT, "JustGo", "Resources", "MetroNetworks"), resources)
    FileUtils.cp(File.join(SOURCE_ROOT, "THIRD_PARTY_NOTICES.md"), @root)
  end

  def rights_validator
    OSSDataValidators::RightsValidator.new(root: @root)
  end

  def initialize_fixture_repository
    git("init")
    git("config", "user.email", "tests@example.com")
    git("config", "user.name", "JustGo Tests")
    git("add", ".")
    git("commit", "-m", "fixture")
  end

  def git(*arguments)
    system("git", *arguments, chdir: @root, out: File::NULL, err: File::NULL, exception: true)
  end

  def city_validator
    OSSDataValidators::CityPackValidator.new(root: @root)
  end

  def mutate_pack(city_id, sync_coverage: false)
    relative_path = "JustGo/Resources/BundledCityPacks/#{city_id}.json"
    pack = read_json(relative_path)
    yield pack
    write_json(relative_path, pack)

    manifest = read_json("DataPacks/manifest.json")
    entry = manifest.fetch("cities").find { |city| city["cityID"] == city_id }
    bytes = File.binread(File.join(@root, relative_path))
    entry["sizeBytes"] = bytes.bytesize
    entry["sha256"] = Digest::SHA256.hexdigest(bytes)
    entry["coverage"] = Marshal.load(Marshal.dump(pack["coverage"])) if sync_coverage
    write_json("DataPacks/manifest.json", manifest)
  end

  def read_json(relative_path)
    JSON.parse(File.read(File.join(@root, relative_path), encoding: "UTF-8"))
  end

  def write_json(relative_path, value)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(value)}\n")
  end

  def empty_coverage
    metric = { "covered" => 0, "total" => 0 }
    {
      "networkStations" => 0,
      "matchedStations" => metric.dup,
      "accessibility" => metric.dup,
      "staticSchedules" => metric.dup,
      "liveArrivals" => metric.dup,
      "externalLayouts" => metric.dup,
      "licensedMedia" => metric.dup,
      "verifiedTransferContexts" => metric.dup
    }
  end
end
