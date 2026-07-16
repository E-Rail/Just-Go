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

queue = Queue.new
urls.each { |url| queue << url }
failures = Queue.new

workers = Array.new(8) do
  Thread.new do
    loop do
      value = queue.pop(true)
      uri = URI(value)
      request = Net::HTTP::Head.new(uri)
      request["User-Agent"] = "JustGo scheduled official-link audit"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) do |http|
        http.request(request)
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
