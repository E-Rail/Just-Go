#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "thread"
require "uri"

ROOT = File.expand_path("..", __dir__)
CATALOG = JSON.parse(File.read(File.join(ROOT, "DataPacks", "official_transit_resources.json")))
urls = CATALOG.fetch("cities").flat_map do |city|
  resources = city.fetch("resources") + city.fetch("stationResources").flat_map { |station| station.fetch("resources") }
  resources.flat_map { |resource| [resource.fetch("targetURL"), resource.fetch("sourcePageURL")] }
end.uniq.sort

USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " \
  "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

queue = Queue.new
urls.each { |url| queue << url }
failures = Queue.new

workers = Array.new(8) do
  Thread.new do
    loop do
      value = queue.pop(true)
      uri = URI(value)
      # An ordinary browser User-Agent, and a GET when HEAD is refused.
      #
      # This sent "Just-Go scheduled official-link audit" and asked only for headers, and most
      # mainland operator sites refuse both. Measured on 2026-09-13: 434 of this audit's 444
      # failures were HTTP 403, and www.bjsubway.com/station/ returns 200 to curl with any
      # ordinary agent and 403 to that string. service.shmetro.com answers 403 to HEAD and 200 to
      # GET. So the report was almost entirely about how the audit asked, not about the links.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) do |http|
        head = Net::HTTP::Head.new(uri)
        head["User-Agent"] = USER_AGENT
        result = http.request(head)
        if result.code.to_i.between?(200, 399)
          result
        else
          get = Net::HTTP::Get.new(uri)
          get["User-Agent"] = USER_AGENT
          http.request(get)
        end
      end
      unless response.code.to_i.between?(200, 399)
        failures << "#{value} -> HTTP #{response.code}"
      end
    rescue ThreadError
      break
    rescue StandardError => error
      failures << "#{value} -> #{error.class}: #{error.message}"
    end
  end
end
workers.each(&:join)

messages = []
messages << failures.pop until failures.empty?
messages.sort.each { |message| warn message }
puts "official link audit: checked=#{urls.length} failures=#{messages.length}"
exit(messages.empty? ? 0 : 1)
