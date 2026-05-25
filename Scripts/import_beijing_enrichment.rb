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
ACCESSIBILITY_URL = "#{BASE_URL}/station/wzass/"
FIRST_LAST_URL = "#{BASE_URL}/station/smcsj/"
DEFAULT_VERSION = "beijing-official-#{Time.now.utc.strftime("%Y%m%d")}"
DEFAULT_OUTPUT = File.expand_path("../DataPacks/packs/1100/#{DEFAULT_VERSION}/city_pack.json", __dir__)
DEFAULT_MANIFEST_OUTPUT = File.expand_path("../DataPacks/manifest.json", __dir__)

def fetch_html(url)
  response = Net::HTTP.get_response(URI(url))
  raise "Fetch failed #{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding("GB18030").encode("UTF-8", invalid: :replace, undef: :replace)
end

def text_content(html)
  text = html
    .gsub(/<br\s*\/?>/i, " ")
    .gsub(/<\/(?:td|th|tr|p|div)>/i, " ")
    .gsub(/<[^>]+>/, " ")
  CGI.unescapeHTML(text)
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
  value.nil? || value.empty? || value == "无" || value.match?(/\A[—\-－]+期?\z/)
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
  records[station_name] ||= {
    "stationName" => station_name,
    "accessibility" => nil,
    "schedules" => []
  }
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
    accessibility = record["accessibility"] ||= {
      "source" => "beijing_official",
      "hasElevator" => nil,
      "hasEscalator" => nil,
      "hasWheelchairRamp" => nil,
      "hasTactilePath" => nil,
      "hasAccessibleRestroom" => nil,
      "elevatorLocations" => [],
      "accessibleEntrances" => [],
      "facilityNotes" => []
    }

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

      note = "#{label}: #{value}"
      accessibility["facilityNotes"] << note unless accessibility["facilityNotes"].include?(note)
    end
  end
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

payload = {
  "schemaVersion" => 1,
  "cityID" => "1100",
  "version" => DEFAULT_VERSION,
  "generatedAt" => Time.now.utc.iso8601,
  "sourceURLs" => [ACCESSIBILITY_URL, FIRST_LAST_URL],
  "capabilities" => {
    "accessibility" => "official_static",
    "schedules" => "official_static",
    "liveArrivals" => "schedule_only",
    "stationMaps" => "source_pending"
  },
  "liveProvider" => "schedule_only",
  "sourceAttribution" => "北京地铁官方数据",
  "stations" => records.values.sort_by { |record| record["stationName"] }.map do |record|
    record.merge(
      "stationID" => nil,
      "stationMaps" => []
    )
  end
}

if dry_run
  schedule_count = payload["stations"].sum { |station| station["schedules"].length }
  accessibility_count = payload["stations"].count { |station| station["accessibility"] }
  warn "stations=#{payload["stations"].length} accessibility=#{accessibility_count} schedules=#{schedule_count}"
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
