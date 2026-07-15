#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "tempfile"
require "uri"

ROOT = File.expand_path("..", __dir__)
COMMONS_API = URI("https://commons.wikimedia.org/w/api.php")
MAX_SOURCE_BYTES = 25 * 1_024 * 1_024
MAX_PIXEL_EDGE = 2_400

MEDIA = [
  {
    title: "File:Beijing_Subway_Jianguomen_Station_01.jpg",
    creator: "Ian Holton",
    license: "CC BY 2.0",
    license_url_fragment: "/licenses/by/2.0/",
    source_size: 3_011_512,
    source_sha1: "682c2dd88704d654c79557a7a5f6d6f518d7f4b8",
    output: "JustGo/Resources/LicensedMedia/beijing-jianguomen.jpg",
    output_size: 470_435,
    output_sha256: "54f8ab6ecab018924e43fb244b5d2d940a100a4680caa799e8e807a721adf750"
  },
  {
    title: "File:Central_station_in_Hong_Kong.jpg",
    creator: "Qqhhss",
    license: "CC0",
    license_url_fragment: "/publicdomain/zero/1.0/",
    source_size: 4_463_295,
    source_sha1: "23ad1d16a17cc4837b960e3606a3e91ee2cdf490",
    output: "JustGo/Resources/LicensedMedia/hong-kong-central.jpg",
    output_size: 955_201,
    output_sha256: "7ef38511d29cee0872787d5ab154bafce6a0089af3bc48508999244ff0840370"
  }
].freeze

class ImportError < StandardError; end

def fetch_https(uri, maximum_bytes:)
  raise ImportError, "HTTPS is required" unless uri.scheme == "https"
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "JustGo licensed-media importer/1.0"
  data = +""
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.request(request) do |response|
      raise ImportError, "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)
      response.read_body do |chunk|
        raise ImportError, "response exceeds #{maximum_bytes} bytes" if data.bytesize + chunk.bytesize > maximum_bytes
        data << chunk
      end
    end
  end
  data
end

def commons_metadata(declaration)
  query = {
    action: "query",
    prop: "imageinfo",
    iiprop: "url|sha1|size|extmetadata",
    titles: declaration.fetch(:title),
    format: "json",
    formatversion: "2"
  }
  uri = COMMONS_API.dup
  uri.query = URI.encode_www_form(query)
  payload = JSON.parse(fetch_https(uri, maximum_bytes: 1_000_000))
  info = payload.dig("query", "pages", 0, "imageinfo", 0)
  raise ImportError, "missing Commons metadata for #{declaration.fetch(:title)}" unless info

  ext = info.fetch("extmetadata")
  artist = ext.dig("Artist", "value").to_s.gsub(/<[^>]+>/, " ")
  license = ext.dig("LicenseShortName", "value").to_s
  license_url = ext.dig("LicenseUrl", "value").to_s
  raise ImportError, "creator mismatch for #{declaration.fetch(:title)}" unless artist.include?(declaration.fetch(:creator))
  raise ImportError, "license mismatch for #{declaration.fetch(:title)}" unless license.include?(declaration.fetch(:license))
  unless license_url.include?(declaration.fetch(:license_url_fragment))
    raise ImportError, "license URL mismatch for #{declaration.fetch(:title)}"
  end
  raise ImportError, "source size mismatch for #{declaration.fetch(:title)}" unless info.fetch("size") == declaration.fetch(:source_size)

  api_sha1 = info.fetch("sha1")
  api_sha1 = format("%040x", api_sha1.to_i(36)) unless api_sha1.match?(/\A[0-9a-f]{40}\z/i)
  unless api_sha1.casecmp?(declaration.fetch(:source_sha1))
    raise ImportError, "source SHA-1 mismatch for #{declaration.fetch(:title)}"
  end

  image_uri = URI(info.fetch("url"))
  unless image_uri.scheme == "https" && image_uri.host == "upload.wikimedia.org"
    raise ImportError, "unexpected Commons media host for #{declaration.fetch(:title)}"
  end
  image_uri
end

def jpeg_dimensions_and_metadata(path)
  data = File.binread(path)
  raise ImportError, "#{path} is not JPEG" unless data.start_with?("\xFF\xD8".b)
  index = 2
  width = nil
  height = nil
  forbidden_metadata = false

  while index + 4 <= data.bytesize
    index += 1 while index < data.bytesize && data.getbyte(index) != 0xFF
    index += 1 while index < data.bytesize && data.getbyte(index) == 0xFF
    break if index >= data.bytesize
    marker = data.getbyte(index)
    index += 1
    break if marker == 0xDA || marker == 0xD9
    next if marker == 0x01 || marker.between?(0xD0, 0xD7)

    raise ImportError, "truncated JPEG segment in #{path}" if index + 2 > data.bytesize
    length = data.byteslice(index, 2).unpack1("n")
    raise ImportError, "invalid JPEG segment in #{path}" if length < 2 || index + length > data.bytesize
    payload = data.byteslice(index + 2, length - 2)
    forbidden_metadata ||= [0xE1, 0xED].include?(marker)
    if [0xC0, 0xC1, 0xC2].include?(marker) && payload.bytesize >= 5
      height, width = payload.byteslice(1, 4).unpack("nn")
    end
    index += length
  end

  raise ImportError, "missing JPEG dimensions in #{path}" unless width && height
  [width, height, forbidden_metadata]
end

def verify_output!(declaration, path)
  raise ImportError, "missing #{path}" unless File.file?(path)
  raise ImportError, "output size mismatch for #{path}" unless File.size(path) == declaration.fetch(:output_size)
  digest = Digest::SHA256.file(path).hexdigest
  raise ImportError, "output SHA-256 mismatch for #{path}" unless digest == declaration.fetch(:output_sha256)
  width, height, forbidden_metadata = jpeg_dimensions_and_metadata(path)
  raise ImportError, "#{path} exceeds #{MAX_PIXEL_EDGE}px" if [width, height].max > MAX_PIXEL_EDGE
  raise ImportError, "#{path} still contains EXIF/XMP/IPTC metadata" if forbidden_metadata
end

def refresh!(declaration)
  magick = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
    .map { |directory| File.join(directory, "magick") }
    .find { |path| File.file?(path) && File.executable?(path) }
  raise ImportError, "ImageMagick is required for developer refresh" unless magick
  source_uri = commons_metadata(declaration)
  source_data = fetch_https(source_uri, maximum_bytes: MAX_SOURCE_BYTES)
  raise ImportError, "downloaded source size mismatch" unless source_data.bytesize == declaration.fetch(:source_size)
  raise ImportError, "downloaded source SHA-1 mismatch" unless Digest::SHA1.hexdigest(source_data) == declaration.fetch(:source_sha1)

  output = File.join(ROOT, declaration.fetch(:output))
  FileUtils.mkdir_p(File.dirname(output))
  Tempfile.create(["justgo-source", ".jpg"]) do |source|
    source.binmode
    source.write(source_data)
    source.flush
    Tempfile.create(["justgo-media", ".jpg"], File.dirname(output)) do |normalized|
      normalized.close
      command = [
        magick, source.path, "-auto-orient", "-resize", "#{MAX_PIXEL_EDGE}x#{MAX_PIXEL_EDGE}>",
        "-strip", "-colorspace", "sRGB", "-quality", "88", normalized.path
      ]
      _stdout, stderr, status = Open3.capture3(*command)
      raise ImportError, "ImageMagick failed: #{stderr}" unless status.success?
      verify_output!(declaration, normalized.path)
      File.rename(normalized.path, output)
    end
  end
end

refresh = ARGV.delete("--refresh")
raise ImportError, "usage: #{File.basename($PROGRAM_NAME)} [--refresh]" unless ARGV.empty?

MEDIA.each do |declaration|
  refresh!(declaration) if refresh
  path = File.join(ROOT, declaration.fetch(:output))
  verify_output!(declaration, path)
  puts "verified #{declaration.fetch(:output)}"
end
