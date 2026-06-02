#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "net/http"
require "digest"
require "set"
require "time"
require "uri"

BASE_URL = "https://www.bjsubway.com"
BJMTR_BASE_URL = "https://www.mtr.bj.cn"
ACCESSIBILITY_URL = "#{BASE_URL}/station/wzass/"
FIRST_LAST_URL = "#{BASE_URL}/station/smcsj/"
BJ_SUBWAY_FACILITY_SEED_URL = "#{BASE_URL}/station/fwss/line5/2013-08-21/50.html"
BJMTR_LINE_URLS = %w[
  https://www.mtr.bj.cn/service/line/line-4.html
  https://www.mtr.bj.cn/service/line/line-daxing.html
  https://www.mtr.bj.cn/service/line/line-14.html
  https://www.mtr.bj.cn/service/line/line-16.html
  https://www.mtr.bj.cn/service/line/line-17.html
].freeze
BJ_SUBWAY_STATIONS_XML_URL = "https://map.bjsubway.com/subwaymap/stations.xml?v=20260515"
BJ_SUBWAY_MAP_XML_URL = "https://map.bjsubway.com/subwaymap/beijing.xml?v=20260515"
BJ_SUBWAY_BLOCKS_URL = "https://map.bjsubway.com/getblocks"
BJ_SUBWAY_REAL_STATUS_URL = "https://map.bjsubway.com/getrealdatas"
DEFAULT_VERSION = "beijing-official-#{Time.now.utc.strftime("%Y%m%d")}"
DEFAULT_OUTPUT = File.expand_path("../DataPacks/packs/1100/#{DEFAULT_VERSION}/city_pack.json", __dir__)
DEFAULT_MANIFEST_OUTPUT = File.expand_path("../DataPacks/manifest.json", __dir__)
HTTP_OPEN_TIMEOUT = 8
HTTP_READ_TIMEOUT = 20

def http_get_response(url)
  uri = URI(url)
  Net::HTTP.start(
    uri.host,
    uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: HTTP_OPEN_TIMEOUT,
    read_timeout: HTTP_READ_TIMEOUT
  ) do |http|
    http.get(uri.request_uri)
  end
end

def fetch_html(url)
  response = http_get_response(url)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("GB18030").encode("UTF-8", invalid: :replace, undef: :replace)
end

def fetch_utf8_html(url)
  response = http_get_response(url)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("UTF-8")
end

def fetch_bytes(url)
  response = http_get_response(url)
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def fetch_json(url)
  JSON.parse(fetch_utf8_html(url))
end

def text_content(html)
  text = html
    .gsub(/<br\s*\/?>/i, " ")
    .gsub(/<\/(?:td|th|tr|p|div)>/i, " ")
    .gsub(/<[^>]+>/, " ")
  CGI.unescapeHTML(text)
    .gsub(/&nbsp;/i, " ")
    .gsub(/\u00a0/, " ")
    .gsub(/[[:space:]]+/, " ")
    .strip
end

def table_blocks(html)
  html.scan(/<table\b.*?<\/table>/mi)
end

def row_blocks(html)
  html.scan(/<tr\b.*?<\/tr>/mi)
end

def cells(row)
  row.scan(/<(?:td|th)\b[^>]*>.*?<\/(?:td|th)>/mi).map { |cell| text_content(cell) }
end

def header_cells(row)
  row.scan(/<(?:td|th)\b([^>]*)>(.*?)<\/(?:td|th)>/mi).map do |attrs, inner|
    colspan = attrs[/colspan\s*=\s*["']?(\d+)/i, 1]&.to_i || 1
    { text: text_content(inner), colspan: colspan }
  end
end

def blank_value?(value)
  value.nil? || value.empty? || value == "无" || value == "暂无" || value.match?(/\A[—\-－]+期?\z/)
end

def usable_time?(value)
  value && value.match?(/\A\d{1,2}:\d{2}\z/)
end

def add_unique(target, values)
  values.each do |value|
    next if blank_value?(value)

    target << value unless target.include?(value)
  end
end

def station_record(records, station_name)
  station_name = normalize_station_name(station_name)
  records[station_name] ||= {
    "stationName" => station_name,
    "accessibility" => nil,
    "schedules" => [],
    "stationAssets" => [],
    "serviceStatus" => nil
  }
end

def normalize_station_name(value)
  value.to_s
    .gsub(/\s+/, "")
    .strip
end

def slug(value)
  normalize_station_name(value)
    .encode("UTF-8")
    .bytes
    .map { |byte| byte.to_s(16).rjust(2, "0") }
    .join
end

def absolute_url(base_url, href)
  return nil if href.nil? || href.empty? || href.start_with?("data:")

  href = "https:#{href}" if href.start_with?("//")
  href = URI::DEFAULT_PARSER.escape(href) unless href.ascii_only?
  URI.join(base_url, href).to_s
end

def asset_extension(url)
  path = URI(url).path
  ext = File.extname(path).downcase.sub(".", "")
  %w[jpg jpeg png webp gif].include?(ext) ? ext : "jpg"
rescue URI::InvalidURIError
  "jpg"
end

def ensure_accessibility(record, source)
  accessibility = record["accessibility"] ||= {
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
  accessibility["source"] = source if accessibility["source"].to_s.empty?
  accessibility
end

def add_facility_note(accessibility, label, value)
  return if blank_value?(label) || blank_value?(value)

  note = "#{label}: #{value}"
  accessibility["facilityNotes"] << note unless accessibility["facilityNotes"].include?(note)
end

def parse_accessibility(html, records)
  row_blocks(html).each do |row|
    row_cells = cells(row)
    next unless row_cells.length >= 9

    station_name = row_cells[0]
    next if station_name.empty? || station_name.include?("车站") || station_name.include?("线路")

    assist_device = row_cells[1]
    stair_climber = row_cells[2]
    platform_lift = row_cells[3]
    ramp = row_cells[4]
    station_elevator = row_cells[5]
    entrance_elevator = row_cells[6]
    tactile_path = row_cells[7]
    restroom = row_cells[8]

    record = station_record(records, station_name)
    accessibility = ensure_accessibility(record, "beijing_official")

    elevator_locations = [station_elevator, entrance_elevator].reject { |value| blank_value?(value) }
    add_unique(accessibility["elevatorLocations"], elevator_locations)
    add_unique(accessibility["accessibleEntrances"], [ramp, entrance_elevator])

    accessibility["hasElevator"] = true unless elevator_locations.empty?
    accessibility["hasWheelchairRamp"] = true unless blank_value?(ramp)
    accessibility["hasTactilePath"] = true unless blank_value?(tactile_path)
    accessibility["hasAccessibleRestroom"] = true unless blank_value?(restroom)

    {
      "召援设备" => assist_device,
      "爬楼车" => stair_climber,
      "升降平台" => platform_lift,
      "无障碍厕所" => restroom
    }.each do |label, value|
      next if blank_value?(value)

      add_facility_note(accessibility, label, value)
    end
  end
end

def bjsubway_station_links(seed_html)
  seed_html
    .scan(/href=["']([^"']*\/station\/fwss\/[^"']+\.html)["'][^>]*>([^<]+)/i)
    .map do |href, name|
      station_name = normalize_station_name(text_content(name))
      next if station_name.empty? || station_name == "服务设施"

      [station_name, absolute_url(BASE_URL, href)]
    end
    .compact
    .uniq
end

def page_image_urls(page_url, html)
  html.scan(/<img\b([^>]+)>/i).map do |attrs_match|
    src = attrs_match.first[/src=["']([^"']+)["']/i, 1]
    next unless src

    absolute_url(page_url, src)
  end.compact.uniq
end

def download_station_asset(source_url, station_name, provider, category, index, output_path, dry_run)
  ext = asset_extension(source_url)
  relative_path = "station_assets/#{provider}/#{category}/#{slug(station_name)}_#{index}.#{ext}"
  return relative_path if dry_run

  asset_path = File.join(File.dirname(output_path), relative_path)
  return relative_path if File.file?(asset_path)

  FileUtils.mkdir_p(File.dirname(asset_path))
  File.binwrite(asset_path, fetch_bytes(source_url))
  relative_path
end

def add_station_asset(record, category, title, relative_path, source_url)
  record["stationAssets"] ||= []
  asset = {
    "category" => category,
    "title" => title,
    "assetURL" => relative_path,
    "assetType" => asset_extension(relative_path),
    "sourceURL" => source_url
  }
  record["stationAssets"] << asset unless record["stationAssets"].any? { |existing| existing["assetURL"] == relative_path }
end

def collect_bjsubway_station_assets(station_name, page_url, html, records, output_path, dry_run)
  record = station_record(records, station_name)
  index_by_category = Hash.new(0)

  page_image_urls(page_url, html).each do |image_url|
    next unless image_url.include?("/d/file/station/")

    category = image_url.include?("/xltcx/") ? "timetable_image" : "facility_image"
    index_by_category[category] += 1
    relative_path = download_station_asset(
      image_url,
      station_name,
      "bjsubway",
      category == "timetable_image" ? "timetable" : "facility",
      index_by_category[category],
      output_path,
      dry_run
    )
    title = category == "timetable_image" ? "#{station_name}官方列车时刻图" : "#{station_name}官方车站设施图"
    add_station_asset(record, category, title, relative_path, page_url)
  rescue StandardError => error
    warn "Skipping Beijing Subway image #{station_name} #{image_url}: #{error.message}"
  end
end

def parse_bjsubway_facility_page(station_name, url, html, records, output_path, dry_run)
  record = station_record(records, station_name)
  record["sourceURLs"] ||= []
  record["sourceURLs"] << url unless record["sourceURLs"].include?(url)
  accessibility = ensure_accessibility(record, "beijing_official")

  html.scan(/<div class="cardpays2?".*?(?=<div class="cardpays2?"|<\/div>\s*<\/div>\s*<div class="other")/mi).each do |block|
    labels = block.scan(/<div class="img_title">(.*?)<\/div>/mi).map { |label| text_content(label.first) }
    location = text_content(block[/<div class="cards_title">(.*?)<\/div>/mi, 1].to_s)
    labels.each do |label|
      case label
      when /直梯|电梯/
        accessibility["hasElevator"] = true
        add_unique(accessibility["elevatorLocations"], [location])
      when /卫生间/
        accessibility["hasAccessibleRestroom"] = true
        add_facility_note(accessibility, label, location)
      else
        add_facility_note(accessibility, label, location)
      end
    end
  end

  collect_bjsubway_station_assets(station_name, url, html, records, output_path, dry_run)
end

def parse_bjsubway_facilities(records, output_path, dry_run)
  seed_html = fetch_html(BJ_SUBWAY_FACILITY_SEED_URL)
  bjsubway_station_links(seed_html).each do |station_name, url|
    parse_bjsubway_facility_page(station_name, url, fetch_html(url), records, output_path, dry_run)
  rescue StandardError => error
    warn "Skipping Beijing Subway facility page #{station_name} #{url}: #{error.message}"
  end
end

def bjsubway_timetable_links(xml)
  xml.scan(/<s\b([^>]*)>/i).map do |attrs_match|
    attrs = attrs_match.first
    station_name = normalize_station_name(attrs[/\bname=["']([^"']+)["']/i, 1])
    href = attrs[/\burl=["']([^"']+)["']/i, 1]
    next if station_name.empty? || href.to_s.empty?

    [station_name, absolute_url(BASE_URL, href)]
  end.compact.uniq
end

def parse_bjsubway_timetable_pages(records, output_path, dry_run)
  xml = fetch_utf8_html(BJ_SUBWAY_STATIONS_XML_URL)
  bjsubway_timetable_links(xml).each do |station_name, url|
    record = station_record(records, station_name)
    record["sourceURLs"] ||= []
    record["sourceURLs"] << url unless record["sourceURLs"].include?(url)
    collect_bjsubway_station_assets(station_name, url, fetch_html(url), records, output_path, dry_run)
  rescue StandardError => error
    warn "Skipping Beijing Subway timetable page #{station_name} #{url}: #{error.message}"
  end
end

def bjmtr_station_links(line_html)
  line_html
    .scan(/href=["']([^"']*\/service\/line\/station\/[^"']+\.html)["'][^>]*>([^<]+)/i)
    .map do |href, name|
      station_name = normalize_station_name(text_content(name))
      next if station_name.empty?

      [station_name, absolute_url(BJMTR_BASE_URL, href)]
    end
    .compact
    .uniq
end

def parse_bjmtr_facilities(html)
  facilities = []
  html.scan(/<section class="facility">(.*?)<\/section>/mi).each do |match|
    block = match.first
    label = text_content(block[/<h3>(.*?)<\/h3>/mi, 1].to_s)
    location = text_content(block.gsub(/<h3>.*?<\/h3>/mi, " "))
    next if blank_value?(label) || blank_value?(location)

    facilities << [label, location]
  end
  facilities.uniq
end

def bjmtr_station_map_url(page_url, station_name, html)
  image = html
    .scan(/<img\b[^>]+>/i)
    .find { |tag| tag.include?("#{station_name}站立体图") || tag.include?("#{station_name}立体图") }
  src = image&.match(/src=["']([^"']+)["']/i)&.captures&.first
  absolute_url(page_url, src)
end

def download_station_map(source_url, station_name, provider, output_path, dry_run)
  ext = asset_extension(source_url)
  relative_path = "station_maps/#{provider}/#{slug(station_name)}.#{ext}"
  return relative_path if dry_run

  asset_path = File.join(File.dirname(output_path), relative_path)
  return relative_path if File.file?(asset_path)

  FileUtils.mkdir_p(File.dirname(asset_path))
  File.binwrite(asset_path, fetch_bytes(source_url))
  relative_path
end

def add_station_map(record, title, relative_path, source_url)
  record["stationMaps"] ||= []
  map = {
    "title" => title,
    "assetURL" => relative_path,
    "assetType" => asset_extension(relative_path),
    "sourceURL" => source_url
  }
  record["stationMaps"] << map unless record["stationMaps"].any? { |existing| existing["assetURL"] == relative_path }
end

def parse_bjmtr_station_page(station_name, url, html, records, output_path, dry_run)
  record = station_record(records, station_name)
  record["sourceURLs"] ||= []
  record["sourceURLs"] << url unless record["sourceURLs"].include?(url)
  accessibility = ensure_accessibility(record, "beijing_official")

  parse_bjmtr_facilities(html).each do |label, location|
    case label
    when /直升电梯|直梯|电梯/
      accessibility["hasElevator"] = true
      add_unique(accessibility["elevatorLocations"], [location])
    when /坡道/
      accessibility["hasWheelchairRamp"] = true
      add_unique(accessibility["accessibleEntrances"], [location])
    when /盲道/
      accessibility["hasTactilePath"] = true
    when /无障碍卫生间/
      accessibility["hasAccessibleRestroom"] = true
      add_facility_note(accessibility, label, location)
    when /紧急呼叫|召援/
      add_facility_note(accessibility, label, location)
    else
      add_facility_note(accessibility, label, location)
    end
  end

  if (map_url = bjmtr_station_map_url(url, station_name, html))
    relative_path = download_station_map(map_url, station_name, "bjmtr", output_path, dry_run)
    add_station_map(record, "#{station_name}站立体图", relative_path, url)
  end
end

def parse_bjmtr_facilities_and_maps(records, output_path, dry_run)
  BJMTR_LINE_URLS.flat_map do |line_url|
    bjmtr_station_links(fetch_utf8_html(line_url))
  rescue StandardError => error
    warn "Skipping BJMTR line #{line_url}: #{error.message}"
    []
  end.uniq.each do |station_name, url|
    parse_bjmtr_station_page(station_name, url, fetch_utf8_html(url), records, output_path, dry_run)
  rescue StandardError => error
    warn "Skipping BJMTR station page #{station_name} #{url}: #{error.message}"
  end
end

def bjsubway_acc_lookup(xml)
  lookup = {}
  xml.scan(/<p\b([^>]*)\/?>/i).each do |attrs_match|
    attrs = attrs_match.first
    acc = attrs[/\bacc=["']([^"']+)["']/i, 1]
    station_name = normalize_station_name(attrs[/\blb=["']([^"']+)["']/i, 1])
    next if acc.to_s.empty? || station_name.empty?

    lookup[acc] = station_name
  end
  lookup
end

def ensure_service_status(record)
  record["serviceStatus"] ||= {
    "accIDs" => [],
    "crowdControlWindows" => [],
    "statusColor" => nil,
    "statusUpdatedAt" => nil
  }
end

def parse_bjsubway_web_map_status(records)
  acc_to_station = bjsubway_acc_lookup(fetch_utf8_html(BJ_SUBWAY_MAP_XML_URL))
  acc_to_station.each do |acc, station_name|
    status = ensure_service_status(station_record(records, station_name))
    status["accIDs"] << acc unless status["accIDs"].include?(acc)
  end

  fetch_json(BJ_SUBWAY_BLOCKS_URL).each do |block|
    station_name = normalize_station_name(block["name"] || acc_to_station[block["acc"].to_s])
    next if station_name.empty?

    status = ensure_service_status(station_record(records, station_name))
    acc = block["acc"].to_s
    status["accIDs"] << acc unless acc.empty? || status["accIDs"].include?(acc)
    window = block["blocktime"].to_s.strip
    status["crowdControlWindows"] << window unless window.empty? || status["crowdControlWindows"].include?(window)
  end

  real_status = fetch_json(BJ_SUBWAY_REAL_STATUS_URL)
  Array(real_status["sr"]).each do |entry|
    station_name = acc_to_station[entry["s"].to_s]
    next if station_name.to_s.empty?

    status = ensure_service_status(station_record(records, station_name))
    status["statusColor"] = entry["color"] if entry["color"]
    status["statusUpdatedAt"] = entry["update_at"] if entry["update_at"]
  end
rescue StandardError => error
  warn "Skipping Beijing Subway web map status: #{error.message}"
end

def previous_city_pack_path(output_path)
  current_pack = File.expand_path(output_path)
  city_dir = File.dirname(File.dirname(current_pack))
  Dir.glob(File.join(city_dir, "*", "city_pack.json"))
    .map { |path| File.expand_path(path) }
    .reject { |path| path == current_pack }
    .sort
    .last
end

def merge_previous_station_maps(records, output_path, dry_run)
  previous_path = previous_city_pack_path(output_path)
  return unless previous_path && File.file?(previous_path)

  previous_pack = JSON.parse(File.read(previous_path))
  previous_base = File.dirname(previous_path)
  current_base = File.dirname(output_path)

  previous_pack.fetch("stations", []).each do |station|
    maps = Array(station["stationMaps"])
    next if maps.empty?

    record = station_record(records, station["stationName"])
    next unless record.fetch("stationMaps", []).empty?

    record["stationMaps"] = maps
    next if dry_run

    maps.each do |station_map|
      asset_url = station_map["assetURL"].to_s
      next if asset_url.empty? || asset_url.match?(%r{\Ahttps?://}i)

      source_path = File.join(previous_base, asset_url)
      destination_path = File.join(current_base, asset_url)
      next unless File.file?(source_path)
      next if File.file?(destination_path)

      FileUtils.mkdir_p(File.dirname(destination_path))
      FileUtils.cp(source_path, destination_path)
    end
  end
rescue StandardError => error
  warn "Skipping previous station map merge: #{error.message}"
end

def schedule_groups(table)
  header_rows = row_blocks(table).take_while { |row| !row.include?("<tbody") }
  candidate = header_rows
    .map { |row| header_cells(row) }
    .find do |row_cells|
      texts = row_cells.map { |cell| cell[:text] }
      row_cells.any? { |cell| cell[:colspan] > 1 } &&
        texts.any? { |text| text.include?("方向") || text.include?("环") || text.start_with?("往") }
    end

  return [] unless candidate

  candidate
    .reject { |cell| cell[:text].include?("车站") || cell[:text].include?("名称") }
    .map { |cell| { direction: cell[:text], count: cell[:colspan] } }
end

def parse_schedules(html, records)
  table_blocks(html).each do |table|
    title = text_content(table[/<tr\b.*?<\/tr>/mi] || "")
    next unless title.include?("首末车时刻表")

    line_name = title.sub(/首末车时刻表.*/, "").strip
    groups = schedule_groups(table)
    next if line_name.empty? || groups.empty?

    row_blocks(table).each do |row|
      row_cells = cells(row)
      next unless row_cells.length >= 3

      station_name = row_cells[0]
      next if station_name.empty? || station_name.include?("车站") || station_name.include?("首车")

      values = row_cells.drop(1)
      offset = 0
      groups.each do |group|
        group_values = values[offset, group[:count]] || []
        offset += group[:count]
        first_time = group_values.find { |value| usable_time?(value) }
        last_times = group_values.drop(1).select { |value| usable_time?(value) }
        next unless first_time || !last_times.empty?

        schedule = {
          "lineName" => line_name,
          "direction" => group[:direction],
          "firstTime" => first_time,
          "lastTime" => last_times.empty? ? nil : last_times.join(" / ")
        }

        record = station_record(records, station_name)
        record["schedules"] << schedule unless record["schedules"].include?(schedule)
      end
    end
  end
end

output_path = DEFAULT_OUTPUT
manifest_output_path = DEFAULT_MANIFEST_OUTPUT
dry_run = false
ARGV.each_with_index do |arg, index|
  case arg
  when "--output"
    output_path = File.expand_path(ARGV.fetch(index + 1))
  when "--manifest-output"
    manifest_output_path = File.expand_path(ARGV.fetch(index + 1))
  when "--dry-run"
    dry_run = true
  end
end

records = {}
parse_accessibility(fetch_html(ACCESSIBILITY_URL), records)
parse_schedules(fetch_html(FIRST_LAST_URL), records)
parse_bjsubway_facilities(records, output_path, dry_run)
parse_bjsubway_timetable_pages(records, output_path, dry_run)
parse_bjsubway_web_map_status(records)
parse_bjmtr_facilities_and_maps(records, output_path, dry_run)
merge_previous_station_maps(records, output_path, dry_run)

source_urls = [
  ACCESSIBILITY_URL,
  FIRST_LAST_URL,
  BJ_SUBWAY_FACILITY_SEED_URL,
  BJ_SUBWAY_STATIONS_XML_URL,
  BJ_SUBWAY_MAP_XML_URL,
  BJ_SUBWAY_BLOCKS_URL,
  BJ_SUBWAY_REAL_STATUS_URL,
  *BJMTR_LINE_URLS
]
station_map_count = records.values.sum { |record| record.fetch("stationMaps", []).length }
station_asset_count = records.values.sum { |record| record.fetch("stationAssets", []).length }
service_status_count = records.values.count { |record| record["serviceStatus"] }

payload = {
  "schemaVersion" => 1,
  "cityID" => "1100",
  "version" => DEFAULT_VERSION,
  "generatedAt" => Time.now.utc.iso8601,
  "sourceURLs" => source_urls,
  "capabilities" => {
    "accessibility" => "official_static",
    "schedules" => "official_static",
    "liveArrivals" => "schedule_only",
    "stationMaps" => station_map_count.positive? ? "official_static" : "source_pending"
  },
  "liveProvider" => "schedule_only",
  "sourceAttribution" => "北京地铁官方数据",
  "stations" => records.values.sort_by { |record| record["stationName"] }.map do |record|
    record.merge(
      "stationID" => nil,
      "stationMaps" => record.fetch("stationMaps", []),
      "stationAssets" => record.fetch("stationAssets", []),
      "serviceStatus" => record["serviceStatus"]
    )
  end
}

if dry_run
  schedule_count = payload["stations"].sum { |station| station["schedules"].length }
  accessibility_count = payload["stations"].count { |station| station["accessibility"] }
  warn "stations=#{payload["stations"].length} accessibility=#{accessibility_count} schedules=#{schedule_count} stationMaps=#{station_map_count} stationAssets=#{station_asset_count} serviceStatus=#{service_status_count}"
  puts JSON.pretty_generate(payload)
else
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, "#{JSON.pretty_generate(payload)}\n")
  pack_data = File.binread(output_path)
  sha256 = Digest::SHA256.hexdigest(pack_data)
  manifest = if File.exist?(manifest_output_path)
               JSON.parse(File.read(manifest_output_path))
             else
               {
                 "schemaVersion" => 1,
                 "generatedAt" => Time.now.utc.iso8601,
                 "primaryHost" => nil,
                 "cities" => []
               }
             end
  city_entry = {
    "cityID" => "1100",
    "version" => payload["version"],
    "sizeBytes" => pack_data.bytesize,
    "sha256" => sha256,
    "downloadURL" => "packs/1100/#{payload["version"]}/city_pack.json",
    "sourceURLs" => payload["sourceURLs"],
    "capabilities" => payload["capabilities"]
  }
  manifest["generatedAt"] = Time.now.utc.iso8601
  manifest["cities"] = manifest.fetch("cities", []).reject { |city| city["cityID"] == "1100" }
  manifest["cities"] << city_entry
  manifest["cities"].sort_by! { |city| city["cityID"] }
  FileUtils.mkdir_p(File.dirname(manifest_output_path))
  File.write(manifest_output_path, "#{JSON.pretty_generate(manifest)}\n")
  puts "Wrote #{output_path}"
  puts "Updated #{manifest_output_path}"
end
