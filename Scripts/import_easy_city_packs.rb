#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "set"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
DEFAULT_MANIFEST_OUTPUT = File.join(DATA_PACKS_DIR, "manifest.json")
VERSION_DATE = Time.now.utc.strftime("%Y%m%d")
HTTP_OPEN_TIMEOUT = 8
HTTP_READ_TIMEOUT = 25

SHENZHEN_STATION_LIST_URL = "https://www.szmc.net/szmc_m/styles/index/zdWeb/js/xlurlList.js"
SHENZHEN_STATION_DETAIL_URL = "https://www.szmc.net/zdxx"
SHENZHEN_SOURCE_URLS = [
  "https://www.szmc.net/szmc_m/styles/index/zdWeb/luohu.html",
  SHENZHEN_STATION_LIST_URL,
  SHENZHEN_STATION_DETAIL_URL
].freeze

CHENGDU_SCHEDULE_PAGE_URL = "https://www.chengdurail.com/ckfw/smbcskb.htm"
CHENGDU_STATION_TIME_URL = "https://www.chengdurail.com/op/station-time"
CHENGDU_SOURCE_URLS = [
  CHENGDU_SCHEDULE_PAGE_URL,
  CHENGDU_STATION_TIME_URL
].freeze

HANGZHOU_STATION_EXAMPLE_URL = "https://www.hzmetro.com/service_1.aspx?Line1=6&Site1=184"
HANGZHOU_OPERATION_API_URL = "https://www.hzmetro.com/api/operation/all"
HANGZHOU_SOURCE_URLS = [
  HANGZHOU_STATION_EXAMPLE_URL,
  HANGZHOU_OPERATION_API_URL
].freeze

def http_request(uri, request)
  attempts = 0
  begin
    attempts += 1
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: HTTP_OPEN_TIMEOUT,
      read_timeout: HTTP_READ_TIMEOUT
    ) do |http|
      http.request(request)
    end
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout
    raise if attempts >= 3

    sleep(0.25 * attempts)
    retry
  end
end

def fetch_utf8(url)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("UTF-8")
end

def post_form_json(url, form_data)
  uri = URI(url)
  request = Net::HTTP::Post.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  request.set_form_data(form_data)
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body.force_encoding("UTF-8"))
end

def post_json(url, payload)
  uri = URI(url)
  request = Net::HTTP::Post.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  request["Referer"] = "https://www.hzmetro.com/"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(payload)
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body.force_encoding("UTF-8"))
end

def normalize_station_name(value)
  value.to_s
    .gsub(/[[:space:]]+/, "")
    .tr("（）", "()")
    .strip
end

def blank_value?(value)
  value.nil? || value.to_s.strip.empty? || value.to_s.strip == "--" || value.to_s.strip == "—" || value.to_s.include?("终点站")
end

def usable_time?(value)
  value.to_s.match?(/\A\d{1,2}:\d{2}\z/)
end

def station_record(records, station_name)
  normalized = normalize_station_name(station_name)
  records[normalized] ||= {
    "stationName" => normalized,
    "stationID" => nil,
    "accessibility" => nil,
    "schedules" => [],
    "stationMaps" => [],
    "stationAssets" => [],
    "serviceStatus" => nil,
    "sourceURLs" => []
  }
end

def add_source(record, url)
  record["sourceURLs"] << url unless record["sourceURLs"].include?(url)
end

def add_schedule(record, line_name, direction, first_time, last_time)
  return if blank_value?(line_name) || blank_value?(direction)
  return unless usable_time?(first_time) || usable_time?(last_time)

  schedule = {
    "lineName" => line_name.to_s.strip,
    "direction" => direction.to_s.strip,
    "firstTime" => usable_time?(first_time) ? first_time : nil,
    "lastTime" => usable_time?(last_time) ? last_time : nil
  }
  record["schedules"] << schedule unless record["schedules"].include?(schedule)
end

def ensure_accessibility(record, source)
  record["accessibility"] ||= {
    "source" => source,
    "hasElevator" => nil,
    "hasEscalator" => nil,
    "hasWheelchairRamp" => nil,
    "hasTactilePath" => nil,
    "hasAccessibleRestroom" => nil,
    "elevatorLocations" => [],
    "accessibleEntrances" => [],
    "facilityNotes" => []
  }
end

def add_facility_note(accessibility, note)
  text = note.to_s.gsub(/[[:space:]]+/, " ").strip
  return if text.empty?

  accessibility["facilityNotes"] << text unless accessibility["facilityNotes"].include?(text)
end

def write_pack(city_id:, version:, source_urls:, capabilities:, live_provider:, source_attribution:, records:)
  output_path = File.join(DATA_PACKS_DIR, "packs", city_id, version, "city_pack.json")
  payload = {
    "schemaVersion" => 1,
    "cityID" => city_id,
    "version" => version,
    "generatedAt" => Time.now.utc.iso8601,
    "sourceURLs" => source_urls,
    "capabilities" => capabilities,
    "liveProvider" => live_provider,
    "sourceAttribution" => source_attribution,
    "stations" => records.values.sort_by { |record| record["stationName"] }
  }

  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, "#{JSON.pretty_generate(payload)}\n")
  puts "Wrote #{output_path} stations=#{payload["stations"].length}"
end

def parse_shenzhen_station_codes
  js = fetch_utf8(SHENZHEN_STATION_LIST_URL)
  codes = {}
  js.scan(/line:\s*['"](\d+)['"].*?zdList:\s*\[(.*?)\]\s*}/m).each do |_line, body|
    body.scan(/name:"([^"]+)".*?code:"(\d+)"/m).each do |name, code|
      codes[code] ||= normalize_station_name(name)
    end
  end
  codes
end

def import_shenzhen
  records = {}
  parse_shenzhen_station_codes.each do |code, station_name|
    detail = post_form_json(SHENZHEN_STATION_DETAIL_URL, "StieCode" => code)
    record = station_record(records, station_name)
    add_source(record, SHENZHEN_STATION_DETAIL_URL)

    Array(detail["workDay"]).each do |row|
      line_name = row["suoshuluxian"]
      add_schedule(record, line_name, "开往 #{row["xinshifangxiang"]}", row["shoubanche"], row["mobanche"])
      add_schedule(record, line_name, "开往 #{row["xinshifangxiangxia"]}", row["shoubanchexia"], row["mobanchexia"])
    end
  rescue StandardError => error
    warn "Skipping Shenzhen station #{station_name} #{code}: #{error.message}"
  end

  write_pack(
    city_id: "4403",
    version: "shenzhen-official-#{VERSION_DATE}",
    source_urls: SHENZHEN_SOURCE_URLS,
    capabilities: {
      "accessibility" => "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "深圳地铁官方数据",
    records: records
  )
end

def import_chengdu
  records = {}
  data = JSON.parse(fetch_utf8(CHENGDU_STATION_TIME_URL))
  Array(data["data"]).each do |line|
    line_name = line["lineName"]
    Array(line["subLine"]).each do |subline|
      direction = subline["description"]
      Array(subline["stationList"]).each do |station|
        record = station_record(records, station["stationName"])
        add_source(record, CHENGDU_STATION_TIME_URL)
        add_schedule(record, line_name, direction, station["startTime"], station["endTime"])
      end
    end
  end

  write_pack(
    city_id: "5101",
    version: "chengdu-official-#{VERSION_DATE}",
    source_urls: CHENGDU_SOURCE_URLS,
    capabilities: {
      "accessibility" => "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "成都轨道交通官方数据",
    records: records
  )
end

def official_facility_sentences(description)
  keywords = %w[无障碍 电梯 垂梯 坡道 斜坡 轮椅 卫生间 第三卫生间 母婴室 AED 宽通道 低位票亭 爱心候车]
  description
    .to_s
    .split(/[。；;\n]/)
    .map(&:strip)
    .select { |sentence| keywords.any? { |keyword| sentence.include?(keyword) } }
    .uniq
    .first(6)
end

def apply_hangzhou_accessibility(record, description)
  notes = official_facility_sentences(description)
  return if notes.empty?

  accessibility = ensure_accessibility(record, "hangzhou_official")
  joined = notes.join("；")
  accessibility["hasElevator"] = true if joined.match?(/无障碍电梯|垂梯|电梯/)
  accessibility["hasWheelchairRamp"] = true if joined.match?(/坡道|斜坡|轮椅斜坡板/)
  accessibility["hasAccessibleRestroom"] = true if joined.match?(/无障碍卫生间|第三卫生间/)
  accessibility["hasTactilePath"] = true if joined.include?("盲道")
  notes.each { |note| add_facility_note(accessibility, note) }
end

def import_hangzhou
  records = {}
  response = post_json(HANGZHOU_OPERATION_API_URL, {})
  raise "Hangzhou API returned #{response["msg"]}" unless response["ok"]

  data = response.fetch("data")
  data.fetch("subwaySiteInfo").each do |line_name, line_infos|
    Array(line_infos).each do |line_info|
      first_by_direction = {}
      Array(line_info["firstTrain"]).each do |direction_group|
        first_by_direction[direction_group["title"]] = Array(direction_group["children"]).to_h do |station|
          [normalize_station_name(station["stationName"]), station["time"]]
        end
      end

      Array(line_info["endTrain"]).each do |direction_group|
        direction = direction_group["title"]
        Array(direction_group["children"]).each do |station|
          station_name = normalize_station_name(station["stationName"])
          record = station_record(records, station_name)
          add_source(record, HANGZHOU_OPERATION_API_URL)
          add_schedule(record, line_name, direction, first_by_direction.fetch(direction, {})[station_name], station["time"])
        end
      end
    end
  end

  Array(data["stationlist"]).each do |station|
    record = station_record(records, station["stationName"])
    add_source(record, HANGZHOU_OPERATION_API_URL)
    apply_hangzhou_accessibility(record, station["description"])
  end

  write_pack(
    city_id: "3301",
    version: "hangzhou-official-#{VERSION_DATE}",
    source_urls: HANGZHOU_SOURCE_URLS,
    capabilities: {
      "accessibility" => records.values.any? { |record| record["accessibility"] } ? "official_static" : "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "杭州地铁官方数据",
    records: records
  )
end

import_shenzhen
import_chengdu
import_hangzhou

system("ruby", File.join(__dir__, "generate_city_pack_manifest.rb"), exception: true)
