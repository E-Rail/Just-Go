#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone runner for the three new city importers: Xi'an, Suzhou, Chongqing.
# Shares helper code with import_easy_city_packs.rb but only invokes the new importers.

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
VERSION_DATE = Time.now.utc.strftime("%Y%m%d")
HTTP_OPEN_TIMEOUT = 8
HTTP_READ_TIMEOUT = 25

XIAN_LINE_STATION_URL = "https://www.xianrail.com/pas-gateway-api/api-basicdata/lineStation/findLineAndStation"
XIAN_STATION_INFO_URL = "https://www.xianrail.com/pas-gateway-api/api-web/aroundSite/getStationInfo"
XIAN_LINE_IDS = %w[01 02 03 04 05 06 08 09 10 14 15 16 50].freeze
XIAN_SOURCE_URLS = [
  "https://www.xianrail.com/",
  XIAN_LINE_STATION_URL,
  XIAN_STATION_INFO_URL
].freeze

SUZHOU_STATION_INFO_URL = "https://www.sz-mtr.com/service/guide/map/javascript/stationInfo_zh.js"
SUZHOU_TIME_URL = "https://www.sz-mtr.com/service/guide/map/javascript/szmtrTime.js"
SUZHOU_SOURCE_URLS = [
  "https://www.sz-mtr.com/",
  SUZHOU_STATION_INFO_URL,
  SUZHOU_TIME_URL
].freeze

CHONGQING_SCHEDULE_URL = "https://www.cqmetro.cn/smbsj/json/data.json"

def http_request(uri, request)
  attempts = 0
  begin
    attempts += 1
    Net::HTTP.start(
      uri.host, uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: HTTP_OPEN_TIMEOUT,
      read_timeout: HTTP_READ_TIMEOUT
    ) { |http| http.request(request) }
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

def post_json_bare(url, payload)
  uri = URI(url)
  request = Net::HTTP::Post.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(payload)
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body.force_encoding("UTF-8"))
end

def normalize_station_name(value)
  value.to_s.gsub(/[[:space:]]+/, "").tr("（）", "()").strip
end

def blank_value?(value)
  value.nil? || value.to_s.strip.empty? || value.to_s.strip == "--" || value.to_s.strip == "—"
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
    "stationFacilities" => [],
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
    "stations" => records.values.sort_by { |r| r["stationName"] }
  }
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, "#{JSON.pretty_generate(payload)}\n")
  puts "Wrote #{output_path} stations=#{payload["stations"].length}"
end

# ── Xi'an ────────────────────────────────────────────────────────────────────

def import_xian
  records = {}
  fetched_ids = {}  # station_id => true, to avoid duplicate API calls
  count = 0

  # The API returns all lines regardless of lineId; one call is sufficient.
  line_data = post_json_bare(XIAN_LINE_STATION_URL, { "lineId" => "01" })
  Array(line_data).each do |line|
    line_name = line["label"].to_s.strip
    Array(line["children"]).each do |child|
      station_id = child["value"].to_s
      next if fetched_ids.key?(station_id)

      fetched_ids[station_id] = true
      station_name = normalize_station_name(child["label"])
      record = station_record(records, station_name)
      add_source(record, XIAN_STATION_INFO_URL)

      begin
        info = JSON.parse(fetch_utf8("#{XIAN_STATION_INFO_URL}?stationId=#{station_id}"))
        Array(info["trainTime"]).each do |train|
          info_line_name = train["lineName"].to_s.strip
          info_line_name = line_name if info_line_name.empty?
          Array(train["timeList"]).each do |schedule|
            add_schedule(record, info_line_name, schedule["direction"], schedule["start"], schedule["end"])
          end
        end
        count += 1
        print "." if count % 10 == 0
      rescue StandardError => error
        warn "\nSkipping Xi'an station #{station_name} #{station_id}: #{error.message}"
      end
    end
  end

  puts "\nXi'an: fetched #{count} stations"
  write_pack(
    city_id: "6101",
    version: "xian-official-#{VERSION_DATE}",
    source_urls: XIAN_SOURCE_URLS,
    capabilities: {
      "accessibility" => "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "西安地铁官方数据",
    records: records
  )
end

# ── Suzhou ───────────────────────────────────────────────────────────────────

def parse_suzhou_time(value)
  return nil if blank_value?(value)
  t = value.to_s.split("#").first.strip
  usable_time?(t) ? t : nil
end

def import_suzhou
  records = {}

  station_js = fetch_utf8(SUZHOU_STATION_INFO_URL)
  station_names = {}
  station_js.scan(/szmtr\.stations\["([^"]+)"\]\s*=\s*\{[^}]*?name:\s*"([^"]+)"/) do |id, name|
    next if name.empty?
    normalized = normalize_station_name(name)
    station_names[id] = normalized
    # Prefixed IDs like "s23_0272" are used as direction endpoints via the bare numeric form "0272"
    if (numeric_id = id.sub(/\As\d+_/, "")) != id
      station_names[numeric_id] ||= normalized
    end
  end
  puts "Suzhou: parsed #{station_names.length} station names"

  time_js = fetch_utf8(SUZHOU_TIME_URL)
  time_js.each_line do |line|
    m = line.match(/szmtr\.metroTimeArray\['([^']+)'\]\s*=\s*new Array\((.+)\);/)
    next unless m

    station_id = m[1]
    array_content = m[2]
    station_name = station_names[station_id]
    next if blank_value?(station_name)

    begin
      entries = JSON.parse("[#{array_content}]")
    rescue JSON::ParserError => error
      warn "Skipping Suzhou station #{station_id}: #{error.message}"
      next
    end

    record = station_record(records, station_name)
    add_source(record, SUZHOU_TIME_URL)

    Array(entries).each do |entry|
      time = entry["Time"]
      next unless time

      line_name = "#{entry["lineID"].to_s.to_i}号线"
      down_dir_name = station_names[time["downDirectionID"]] || time["downDirectionID"]
      up_dir_name   = station_names[time["upDirectionID"]]   || time["upDirectionID"]

      add_schedule(record, line_name, "开往#{down_dir_name}",
                   parse_suzhou_time(time["down_begintime"]),
                   parse_suzhou_time(time["down_endtime"]))
      add_schedule(record, line_name, "开往#{up_dir_name}",
                   parse_suzhou_time(time["up_begintime"]),
                   parse_suzhou_time(time["up_endtime"]))
    end
  end

  write_pack(
    city_id: "3205",
    version: "suzhou-official-#{VERSION_DATE}",
    source_urls: SUZHOU_SOURCE_URLS,
    capabilities: {
      "accessibility" => "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "苏州轨道交通官方数据",
    records: records
  )
end

# ── Chongqing ────────────────────────────────────────────────────────────────

def extract_cq_cell(cell_value)
  cell_value.to_s
    .sub(/\(\d+,\s*\d+\)\s*$/, "")
    .gsub(/[↓↑]/, "")
    .strip
end

def import_chongqing
  records = {}
  data = JSON.parse(fetch_utf8(CHONGQING_SCHEDULE_URL))

  Array(data).each do |line|
    line_name = line["lineName"].to_s.strip
    rows = Array(line["scheduls"])
    next if rows.length < 4

    dir_row = rows[2]
    dir1 = extract_cq_cell(dir_row["col2"]).sub(/\A开?往/, "")
    dir2 = extract_cq_cell(dir_row["col3"]).sub(/\A开?往/, "")

    rows[3..].each do |row|
      station_name = extract_cq_cell(row["col1"])
      next if blank_value?(station_name) || station_name.include?("站点")

      first_down = extract_cq_cell(row["col2"])
      first_up   = extract_cq_cell(row["col3"])
      last_down  = extract_cq_cell(row["col4"])
      last_up    = extract_cq_cell(row["col5"])

      record = station_record(records, station_name)
      add_source(record, CHONGQING_SCHEDULE_URL)
      add_schedule(record, line_name, "开往#{dir1}", first_down, last_down) unless blank_value?(dir1)
      add_schedule(record, line_name, "开往#{dir2}", first_up,   last_up)   unless blank_value?(dir2)
    end
  end

  write_pack(
    city_id: "5000",
    version: "chongqing-official-#{VERSION_DATE}",
    source_urls: [CHONGQING_SCHEDULE_URL],
    capabilities: {
      "accessibility" => "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "重庆轨道交通官方数据",
    records: records
  )
end

# ── Run ──────────────────────────────────────────────────────────────────────

puts "=== Importing Xi'an ==="
import_xian

puts "=== Importing Suzhou ==="
import_suzhou

puts "=== Importing Chongqing ==="
import_chongqing

puts "=== Regenerating manifest ==="
system("ruby", File.join(__dir__, "generate_city_pack_manifest.rb"), exception: true)

puts "Done."
