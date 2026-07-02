#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "set"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
DATA_PACKS_DIR = File.join(ROOT, "DataPacks")
VERSION_DATE = Time.now.utc.strftime("%Y%m%d")
HTTP_OPEN_TIMEOUT = 8
HTTP_READ_TIMEOUT = 25

QINGDAO_BASE_URL = "http://www.qd-metro.com"
QINGDAO_EXECUTE_URL = "#{QINGDAO_BASE_URL}/data/execute.php"
QINGDAO_OPERATE_URL = "#{QINGDAO_BASE_URL}/operate.php"
QINGDAO_LINES = {
  "1" => { name: "1号线", asset: "images/timetable/one/onetime.png" },
  "2" => { name: "2号线", asset: "images/timetable/two/twotime.png" },
  "3" => { name: "3号线", asset: "images/timetable/three/threetime.png" },
  "4" => { name: "4号线", asset: "images/timetable/four/fourtime.png" },
  "6" => { name: "6号线", asset: "images/timetable/six/sixtime.png" },
  "8" => { name: "8号线", asset: "images/timetable/eight/eighttime.png" },
  "11" => { name: "蓝谷快线", asset: "images/timetable/lg/lgtime.png" },
  "13" => { name: "西海岸快线", asset: "images/timetable/xha/xhatime.png" }
}.freeze

SOURCE_URLS = [
  QINGDAO_OPERATE_URL,
  QINGDAO_EXECUTE_URL
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
    ) { |http| http.request(request) }
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout
    raise if attempts >= 3

    sleep(0.25 * attempts)
    retry
  end
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

def fetch_binary(url)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def normalize_station_name(value)
  value.to_s.gsub(/[[:space:]]+/, "").tr("（）", "()").strip
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

def facility_type(title)
  text = title.to_s.downcase
  return "elevator" if text.include?("电梯") || text.include?("升降")
  return "escalator" if text.include?("扶梯")
  return "accessibleRestroom" if text.include?("无障碍卫生间")
  return "restroom" if text.include?("卫生间") || text.include?("厕所")
  return "aed" if text.include?("aed") || text.include?("除颤")
  return "motherBabyRoom" if text.include?("母婴")
  return "serviceCenter" if text.include?("客服") || text.include?("服务中心")
  return "security" if text.include?("公安") || text.include?("警务")

  "general"
end

def merge_unique_array(record, key, values)
  existing = record[key] || []
  values.each { |value| existing << value unless existing.include?(value) }
  record[key] = existing
end

def add_asset(record, title, relative_path)
  asset = {
    "category" => "timetable_image",
    "title" => title,
    "assetURL" => relative_path,
    "assetType" => "png",
    "sourceURL" => QINGDAO_OPERATE_URL
  }
  record["stationAssets"] << asset unless record["stationAssets"].any? { |item| item["assetURL"] == relative_path }
end

def add_facility(record, station_name, title, content)
  name = title.to_s.strip
  location = content.to_s.strip
  return if name.empty? && location.empty?

  facility = {
    "id" => "#{station_name}-#{name}-#{location}",
    "type" => facility_type(name),
    "name" => name.empty? ? location : name,
    "locationText" => location.empty? ? nil : location
  }
  key = [facility["type"], facility["name"], facility["locationText"]].join("|")
  return if record["stationFacilities"].any? { |item| [item["type"], item["name"], item["locationText"]].join("|") == key }

  record["stationFacilities"] << facility
end

def fetch_station_data(site_id)
  post_form_json(QINGDAO_EXECUTE_URL, { "act" => "siteData", "ids" => site_id.to_s })
rescue StandardError => error
  warn "Skipping Qingdao station data #{site_id}: #{error.message}"
  nil
end

def apply_station_data(record, site_data)
  station_name = record["stationName"]
  exit_names = Array(site_data["crktype"]).map { |item| item["exit"].to_s.strip }.reject(&:empty?)
  exit_notes = Array(site_data["crkdata"]).map do |item|
    exit_name = item["exit"].to_s.strip
    title = item["title"].to_s.strip
    [exit_name, title].reject(&:empty?).join(": ")
  end.reject(&:empty?)

  Array(site_data["ssdata"]).each do |item|
    add_facility(record, station_name, item["title"], item["content"])
  end
  exit_notes.each do |note|
    add_facility(record, station_name, "出入口", note)
  end

  elevator_locations = Array(site_data["ssdata"])
    .select { |item| item["title"].to_s.include?("无障碍电梯") }
    .map { |item| [item["title"], item["content"]].compact.join(": ") }
    .reject(&:empty?)

  accessibility = record["accessibility"] || {
    "source" => "青岛地铁官方网站",
    "hasElevator" => nil,
    "hasEscalator" => nil,
    "hasWheelchairRamp" => nil,
    "hasTactilePath" => nil,
    "hasAccessibleRestroom" => nil,
    "elevatorLocations" => [],
    "accessibleEntrances" => [],
    "facilityNotes" => []
  }
  accessibility["hasElevator"] = true if elevator_locations.any?
  accessibility["hasEscalator"] = true if Array(site_data["ssdata"]).any? { |item| item["title"].to_s.include?("自动扶梯") }
  accessibility["hasAccessibleRestroom"] = true if Array(site_data["ssdata"]).any? { |item| item["title"].to_s.include?("无障碍卫生间") }
  merge_unique_array(accessibility, "elevatorLocations", elevator_locations)
  merge_unique_array(accessibility, "accessibleEntrances", exit_names)
  merge_unique_array(accessibility, "facilityNotes", exit_notes + record["stationFacilities"].map { |item| [item["name"], item["locationText"]].compact.join(": ") })
  record["accessibility"] = accessibility
end

version = "qingdao-official-#{VERSION_DATE}"
output_dir = File.join(DATA_PACKS_DIR, "packs", "3702", version)
assets_dir = File.join(output_dir, "assets", "timetable")
FileUtils.mkdir_p(assets_dir)

asset_paths = {}
QINGDAO_LINES.each do |line_id, config|
  relative_path = File.join("assets", "timetable", File.basename(config[:asset]))
  target_path = File.join(output_dir, relative_path)
  FileUtils.mkdir_p(File.dirname(target_path))
  File.binwrite(target_path, fetch_binary("#{QINGDAO_BASE_URL}/#{config[:asset]}"))
  asset_paths[line_id] = relative_path
end

records = {}
seen_site_ids = Set.new
QINGDAO_LINES.each do |line_id, config|
  stations = post_form_json(QINGDAO_EXECUTE_URL, { "act" => "siteSearch", "line" => line_id })
  Array(stations).each do |station|
    station_name = normalize_station_name(station["title"].to_s.empty? ? "#{station["value"]}#{station["text"]}" : station["title"])
    next if station_name.empty?

    record = station_record(records, station_name)
    add_source(record, QINGDAO_OPERATE_URL)
    add_source(record, QINGDAO_EXECUTE_URL)
    add_asset(record, "#{config[:name]}首末车时刻表", asset_paths.fetch(line_id))

    site_id = station["id"].to_s
    next if site_id.empty? || seen_site_ids.include?(site_id)

    seen_site_ids << site_id
    site_data = fetch_station_data(site_id)
    apply_station_data(record, site_data) if site_data
  end
end

payload = {
  "schemaVersion" => 1,
  "cityID" => "3702",
  "version" => version,
  "generatedAt" => Time.now.utc.iso8601,
  "sourceURLs" => SOURCE_URLS,
  "capabilities" => {
    "accessibility" => "official_static",
    "schedules" => "source_pending",
    "liveArrivals" => "source_pending",
    "stationMaps" => "source_pending"
  },
  "liveProvider" => "source_pending",
  "sourceAttribution" => "青岛地铁官方网站",
  "stations" => records.values.sort_by { |record| record["stationName"] }
}

File.write(File.join(output_dir, "city_pack.json"), "#{JSON.pretty_generate(payload)}\n")
puts "Wrote #{File.join(output_dir, "city_pack.json")} stations=#{payload["stations"].length}"
