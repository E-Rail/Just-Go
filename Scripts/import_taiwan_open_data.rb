#!/usr/bin/env ruby
# frozen_string_literal: true

# Vendors the Taipei open-data snapshots that the OSS city-pack pipeline builds city 7101 from.
# Mirrors the Hong Kong arrangement: the network fetch happens here and its exact bytes are
# committed under DataPacks/sources/, so `generate_city_pack_manifest.rb` and CI stay offline
# and deterministic.
#
# Source:  臺北市資料大平臺 (data.taipei), published by 臺北大眾捷運股份有限公司.
# Licence: 政府資料開放授權條款－第1版 / Open Government Data License, Taiwan, version 1.0
#          https://data.gov.tw/license — redistribution, commercial use and derivative works
#          are all permitted; attribution is mandatory and omitting it voids the grant.
#
# TDX (tdx.transportdata.tw) carries the same material behind an API key. These municipal
# datasets are the same licence without the credential, which keeps the build reproducible
# from a clean checkout.
#
# Usage: ruby Scripts/import_taiwan_open_data.rb [--refresh]

require "csv"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "uri"

ROOT = File.expand_path("..", __dir__)
LICENSE_NAME = "Open Government Data License, Taiwan, version 1.0"
LICENSE_URL = "https://data.gov.tw/license"
ATTRIBUTION = "臺北大眾捷運股份有限公司 / 臺北市資料大平臺 (data.taipei)"

RESOURCES = [
  {
    city_id: "7101",
    file_name: "station_exits.csv",
    encoding: "BIG5",
    dataset_page_url: "https://data.gov.tw/dataset/128428",
    source_url: "https://data.taipei/api/dataset/cfa4778c-62c1-497b-b704-756231de348b/" \
      "resource/307a7f61-e302-4108-a817-877ccbfca7c1/download",
    description: "臺北捷運車站出入口座標"
  },
  {
    city_id: "7101",
    file_name: "stations.csv",
    encoding: "UTF-8",
    dataset_page_url: "https://data.gov.tw/dataset/131734",
    source_url: "https://data.taipei/api/dataset/1eefa68d-7c8d-491b-8e75-66a161947426/" \
      "resource/c77e91bf-067c-475e-917b-545ff62b7d76/download",
    description: "臺北捷運車站資料"
  }
].freeze

def download(url)
  uri = URI(url)
  5.times do
    request = Net::HTTP::Get.new(uri)
    # data.taipei answers non-browser agents with an error page rather than the file.
    request["User-Agent"] = "Mozilla/5.0 (compatible; JustGo open-data importer)"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: 30, read_timeout: 120) { |http| http.request(request) }
    return response.body if response.is_a?(Net::HTTPSuccess)
    if response.is_a?(Net::HTTPRedirection)
      uri = URI(response["location"])
      next
    end
    abort "Taiwan open-data import failed: #{url} returned HTTP #{response.code}"
  end
  abort "Taiwan open-data import failed: too many redirects for #{url}"
end

refresh = ARGV.delete("--refresh")
entries = []

RESOURCES.each do |resource|
  dir = File.join(ROOT, "DataPacks", "sources", resource.fetch(:city_id))
  FileUtils.mkdir_p(dir)
  path = File.join(dir, resource.fetch(:file_name))

  if File.file?(path) && !refresh
    body = File.binread(path)
  else
    raw = download(resource.fetch(:source_url))
    # Normalise to UTF-8 so the committed bytes are readable and diffable; the upstream
    # encoding is recorded below so the transformation stays auditable.
    body = raw.dup.force_encoding(resource.fetch(:encoding)).encode("UTF-8")
    body = body.sub(/\A﻿/, "")
    body += "\n" unless body.end_with?("\n")
    File.binwrite(path, body)
  end

  rows = CSV.parse(body, headers: true)
  entries << {
    "cityID" => resource.fetch(:city_id),
    "fileName" => resource.fetch(:file_name),
    "description" => resource.fetch(:description),
    "sourceURL" => resource.fetch(:source_url),
    "datasetLandingPageURL" => resource.fetch(:dataset_page_url),
    "sourceEncoding" => resource.fetch(:encoding),
    "sizeBytes" => body.bytesize,
    "sha256" => Digest::SHA256.hexdigest(body),
    "csvRecordCount" => rows.length,
    "headers" => rows.headers
  }
  puts "#{resource.fetch(:file_name)}: #{rows.length} rows"
end

metadata = {
  "schemaVersion" => 1,
  "platform" => "臺北市資料大平臺 (data.taipei)",
  "provider" => "臺北大眾捷運股份有限公司 Taipei Rapid Transit Corporation",
  "rightsID" => "taipei-open-data",
  "licenseName" => LICENSE_NAME,
  "licenseURL" => LICENSE_URL,
  "attribution" => ATTRIBUTION,
  "resources" => entries.sort_by { |entry| entry.fetch("fileName") }
}
File.write(
  File.join(ROOT, "DataPacks", "sources", "7101", "metadata.json"),
  "#{JSON.pretty_generate(metadata)}\n"
)

puts "Taipei open-data snapshot ok: files=#{entries.length}"
