#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/official_transit_resource_importer"

class OfficialTransitResourceImporterTest < Minitest::Test
  def test_system_parser_deduplicates_identical_interchange_rows
    rows = (1..98).map do |index|
      code = format("s%02d", index)
      row("Station #{index}", "/archive/ch/services/maps/#{code}.pdf", "/archive/ch/services/layouts/#{code}.pdf")
    end
    rows << row("Station 1", "/archive/ch/services/maps/s01.pdf", "/archive/ch/services/layouts/s01.pdf")
    html = %(<a href="/archive/en/services/routemap.pdf">Map</a><table>#{rows.join}</table>)

    parsed = OfficialTransitResourceImporter.parse_system_index(html)

    assert_equal 98, parsed.fetch("stations").length
    assert_equal "/archive/en/services/routemap.pdf", parsed.fetch("systemMapPath")
  end

  def test_system_parser_rejects_conflicting_duplicate_code
    rows = (1..98).map do |index|
      code = format("s%02d", index)
      row("Station #{index}", "/archive/ch/services/maps/#{code}.pdf", "/archive/ch/services/layouts/#{code}.pdf")
    end
    rows << row("Different", "/archive/ch/services/maps/s01.pdf", "/archive/ch/services/layouts/s01.pdf")
    html = %(<a href="/archive/en/services/routemap.pdf">Map</a><table>#{rows.join}</table>)

    assert_raises(OfficialTransitResourceImporter::ImportError) do
      OfficialTransitResourceImporter.parse_system_index(html)
    end
  end

  def test_light_rail_parser_preserves_explicit_stop_groups
    rows = (1..14).map do |index|
      %(<tr><td><a href="/archive/en/services/lrt_#{format('%02d', index)}.pdf">Map #{index}</a></td><td>Stop #{index}A<br>Stop #{index}B</td></tr>)
    end

    parsed = OfficialTransitResourceImporter.parse_light_rail_index("<table>#{rows.join}</table>")

    assert_equal 14, parsed.length
    assert_equal ["Stop 1A", "Stop 1B"], parsed.first.fetch("stops")
  end

  def test_light_rail_parser_rejects_duplicate_stop_mapping
    rows = (1..14).map do |index|
      stop = index == 14 ? "Stop 1" : "Stop #{index}"
      %(<tr><td><a href="/archive/en/services/lrt_#{format('%02d', index)}.pdf">Map #{index}</a></td><td>#{stop}</td></tr>)
    end

    assert_raises(OfficialTransitResourceImporter::ImportError) do
      OfficialTransitResourceImporter.parse_light_rail_index("<table>#{rows.join}</table>")
    end
  end

  private

  def row(name, location, layout)
    %(<tr><td>#{name}</td><td><a href="#{location}">Download</a></td><td><a href="#{layout}">Download</a></td></tr>)
  end
end
