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

SHANGHAI_PCA_URL = "https://service.shmetro.com/skin/js/pca.js"
SHANGHAI_STATION_INFO_URL = "http://m.shmetro.com/interface/metromap/metromap.aspx"
SHANGHAI_SOURCE_URLS = [
  "https://service.shmetro.com/hcskb/index.htm",
  "https://service.shmetro.com/wzai/index.htm",
  "https://service.shmetro.com/cw/index.htm",
  SHANGHAI_PCA_URL,
  "#{SHANGHAI_STATION_INFO_URL}?func=stationInfo&stat_id=111"
].freeze

GUANGZHOU_API_BASE = "https://apis.gzmtr.com"
# Public parameters used by Guangzhou Metro's own passenger-service web page.
# These are not JustGo secrets and are used only by this offline importer.
GUANGZHOU_ACCESS_KEY = "247919A174804353AE72BAB00981C6E8"
GUANGZHOU_AUTHORIZATION = "Bearer 38c7e7b3ka1f3k44dak8707k806a1f8bf978"
GUANGZHOU_SOURCE_URLS = [
  "https://cs.gzmtr.com/ckfw/stationInfo/index.html",
  "https://cs.gzmtr.com/ckfw/images/ajaxUtil.js",
  "#{GUANGZHOU_API_BASE}/app-map/metroweb/linestation",
  "#{GUANGZHOU_API_BASE}/app-map/serviceTime/list/体育西路",
  "#{GUANGZHOU_API_BASE}/app-map/station/getDevice/体育西路"
].freeze

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

def post_guangzhou_api(path)
  url = "#{GUANGZHOU_API_BASE}#{path}?auto_type=key&acccesskey=#{GUANGZHOU_ACCESS_KEY}"
  uri = URI(url)
  request = Net::HTTP::Post.new(uri)
  request["User-Agent"] = "Mozilla/5.0"
  request["Content-Type"] = "application/json"
  request["Authorization"] = GUANGZHOU_AUTHORIZATION
  response = http_request(uri, request)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  json = JSON.parse(response.body.force_encoding("UTF-8"))
  raise "Guangzhou API failed #{path}" if json.key?("success") && !json["success"]

  json["businessObject"]
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

def extract_js_object(script, variable_name)
  marker = "var #{variable_name} = "
  start = script.index(marker)
  raise "Missing JS variable #{variable_name}" unless start

  index = start + marker.length
  raise "Missing object for #{variable_name}" unless script[index] == "{"

  depth = 0
  in_string = false
  escape = false
  index.upto(script.length - 1) do |offset|
    char = script[offset]
    if in_string
      if escape
        escape = false
      elsif char == "\\"
        escape = true
      elsif char == "\""
        in_string = false
      end
      next
    end

    if char == "\""
      in_string = true
    elsif char == "{"
      depth += 1
    elsif char == "}"
      depth -= 1
      return JSON.parse(script[index..offset]) if depth.zero?
    end
  end

  raise "Unclosed JS object #{variable_name}"
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

def seconds_to_time(value)
  seconds = value.to_i
  return nil if seconds <= 60

  hours = (seconds / 3600) % 24
  minutes = (seconds % 3600) / 60
  format("%02d:%02d", hours, minutes)
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

def add_station_facility(record, type, name, location_text = nil)
  text = name.to_s.gsub(/[[:space:]]+/, " ").strip
  location = location_text.to_s.gsub(/[[:space:]]+/, " ").strip
  return if text.empty?

  facility = {
    "type" => type,
    "name" => text,
    "locationText" => location.empty? ? nil : location,
    "source" => "officialCityPack",
    "verification" => "verified"
  }
  record["stationFacilities"] << facility unless record["stationFacilities"].include?(facility)
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

def import_shanghai
  records = {}
  pca = fetch_utf8(SHANGHAI_PCA_URL).sub(/\A\xEF\xBB\xBF/, "")
  stations = extract_js_object(pca, "stations")
  lines = extract_js_object(pca, "lines")
  timetables = extract_js_object(pca, "smbctm")
  numeric_station_names = stations.to_h { |key, name| [key.to_s.sub(/\A0+/, ""), normalize_station_name(name)] }
  line_by_numeric_station = {}

  lines.each do |line_name, station_ids|
    Array(station_ids).each do |station_id|
      line_by_numeric_station[station_id.to_s.sub(/\A0+/, "")] ||= line_name
    end
  end

  timetables.each do |destination_key, table|
    destination = numeric_station_names[destination_key.to_s.sub(/\A0+/, "")]
    next if blank_value?(destination)

    station_ids = table[0].to_s.split("-")
    first_times = table[1].to_s.split("-")
    last_times = table[2].to_s.split("-")
    line_name = line_by_numeric_station[station_ids.first] || line_by_numeric_station[destination_key.to_s.sub(/\A0+/, "")]
    next if blank_value?(line_name)

    station_ids.each_with_index do |station_id, index|
      station_name = numeric_station_names[station_id]
      next if blank_value?(station_name)

      record = station_record(records, station_name)
      add_source(record, SHANGHAI_PCA_URL)
      add_schedule(record, line_name, "开往 #{destination}", seconds_to_time(first_times[index]), seconds_to_time(last_times[index]))
    end
  end

  stations.keys.map { |key| key.to_s.sub(/\A0+/, "") }.uniq.each do |station_id|
    station_info_url = "#{SHANGHAI_STATION_INFO_URL}?func=stationInfo&stat_id=#{CGI.escape(station_id)}"
    response = fetch_utf8(station_info_url)
    data = JSON.parse(response)
    station = Array(data).first
    next unless station && !blank_value?(station["name_cn"])

    record = station_record(records, station["name_cn"])
    add_source(record, station_info_url)
    accessibility = ensure_accessibility(record, "shanghai_metro_official")

    begin
      elevator_data = JSON.parse(station["elevator"].to_s)
      Array(elevator_data["line"]).each do |line|
        Array(line["elevator"]).each do |elevator|
          description = elevator["description"]
          next if blank_value?(description)

          accessibility["hasElevator"] = true
          accessibility["elevatorLocations"] << description unless accessibility["elevatorLocations"].include?(description)
          add_facility_note(accessibility, "无障碍电梯：#{description}")
          add_station_facility(record, "elevator", "无障碍电梯", description)
        end
      end
    rescue JSON::ParserError
      nil
    end

    begin
      toilet_data = JSON.parse(station["toilet_position"].to_s)
      Array(toilet_data["toilet"]).each do |toilet|
        description = toilet["description"]
        next if blank_value?(description)

        if toilet["icon2"].to_s != "w_os.png"
          accessibility["hasAccessibleRestroom"] = true
          add_facility_note(accessibility, "无障碍卫生间：#{description}")
          add_station_facility(record, "accessibleRestroom", "无障碍卫生间", description)
        else
          add_station_facility(record, "restroom", "卫生间", description)
        end
      end
    rescue JSON::ParserError
      nil
    end
  rescue StandardError => error
    warn "Skipping Shanghai station #{station_id}: #{error.message}"
  end

  write_pack(
    city_id: "3100",
    version: "shanghai-official-#{VERSION_DATE}",
    source_urls: SHANGHAI_SOURCE_URLS,
    capabilities: {
      "accessibility" => records.values.any? { |record| record["accessibility"] } ? "official_static" : "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "上海地铁官方数据",
    records: records
  )
end

def guangzhou_facility_type(name)
  normalized = name.to_s.strip
  return "elevator" if normalized.include?("电梯") || normalized.include?("升降机")
  return "escalator" if normalized.include?("扶梯")
  return "ramp" if normalized.include?("斜坡") || normalized.include?("坡道")
  return "tactilePath" if normalized.include?("盲道")
  return "accessibleRestroom" if normalized.include?("无障碍") && normalized.match?(/公厕|卫生间|厕所/)
  return "restroom" if normalized.match?(/公厕|卫生间|厕所/)
  return "aed" if normalized.match?(/AED|急救/i)
  return "motherBabyRoom" if normalized.include?("母婴")
  return "serviceCenter" if normalized.match?(/客服|服务/)
  return "general"
end

def import_guangzhou
  records = {}
  line_station_data = Array(post_guangzhou_api("/app-map/metroweb/linestation"))
  station_names = Set.new
  line_station_data.each do |line|
    line_name = line["lineName"]
    Array(line["stations"]).each do |station|
      name = normalize_station_name(station["stationName"])
      next if blank_value?(name)

      station_names << name
      record = station_record(records, name)
      add_source(record, "#{GUANGZHOU_API_BASE}/app-map/metroweb/linestation")
      Array(station["hcLines"]).each { |hc_line| add_source(record, "#{GUANGZHOU_API_BASE}/app-map/metroweb/linestation") if hc_line["lineName"] }
      record["stationID"] ||= station["stationId"].to_s if station["stationId"]
    end
  end

  station_names.each do |station_name|
    encoded_name = CGI.escape(station_name)
    record = station_record(records, station_name)

    Array(post_guangzhou_api("/app-map/serviceTime/list/#{encoded_name}")).each do |row|
      add_source(record, "#{GUANGZHOU_API_BASE}/app-map/serviceTime/list/#{station_name}")
      add_schedule(record, row["lineCn"], "开往 #{row["toStationName"]}", row["startTime"], row["endTime"])
    end

    Array(post_guangzhou_api("/app-map/station/getDevice/#{encoded_name}")).each do |device|
      name = device["nameCN"].to_s.strip
      location = device["locationCN"].to_s.strip
      next if blank_value?(name) || blank_value?(location)

      add_source(record, "#{GUANGZHOU_API_BASE}/app-map/station/getDevice/#{station_name}")
      type = guangzhou_facility_type(name)
      add_station_facility(record, type, name, location)

      accessibility = ensure_accessibility(record, "guangzhou_metro_official") if %w[elevator escalator ramp tactilePath accessibleRestroom].include?(type)
      next unless accessibility

      case type
      when "elevator"
        accessibility["hasElevator"] = true
        accessibility["elevatorLocations"] << location unless accessibility["elevatorLocations"].include?(location)
      when "escalator"
        accessibility["hasEscalator"] = true
      when "ramp"
        accessibility["hasWheelchairRamp"] = true
        accessibility["accessibleEntrances"] << location unless accessibility["accessibleEntrances"].include?(location)
      when "tactilePath"
        accessibility["hasTactilePath"] = true
      when "accessibleRestroom"
        accessibility["hasAccessibleRestroom"] = true
      end
      add_facility_note(accessibility, "#{name}：#{location}")
    end
  rescue StandardError => error
    warn "Skipping Guangzhou station #{station_name}: #{error.message}"
  end

  write_pack(
    city_id: "4401",
    version: "guangzhou-official-#{VERSION_DATE}",
    source_urls: GUANGZHOU_SOURCE_URLS,
    capabilities: {
      "accessibility" => records.values.any? { |record| record["accessibility"] } ? "official_static" : "source_pending",
      "schedules" => "official_static",
      "liveArrivals" => "schedule_only",
      "stationMaps" => "source_pending"
    },
    live_provider: "schedule_only",
    source_attribution: "广州地铁官方数据",
    records: records
  )
end

def import_xian
  records = {}
  fetched_ids = {}

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
      rescue StandardError => error
        warn "Skipping Xi'an station #{station_name} #{station_id}: #{error.message}"
      end
    end
  end

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
      up_dir_name = station_names[time["upDirectionID"]] || time["upDirectionID"]

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

    # Row index 2 contains direction terminal names in col2 (↓) and col3 (↑)
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

import_shanghai
import_guangzhou
import_shenzhen
import_chengdu
import_hangzhou
import_xian
import_suzhou
import_chongqing

system("ruby", File.join(__dir__, "generate_city_pack_manifest.rb"), exception: true)
