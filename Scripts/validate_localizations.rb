#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"

ROOT = File.expand_path("..", __dir__)
LOCALES = %w[en zh-Hans zh-Hant].freeze
REQUIRED_INFO_KEYS = %w[
  NSLocationWhenInUseUsageDescription
].freeze
ENTRY_PATTERN = /^\s*"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";\s*$/
PLACEHOLDER_PATTERN = /%(?:\d+\$)?[@dfius]/
LITERAL_LOCALIZATION_PATTERN = /AppLocalization\.localized\(\s*"((?:\\.|[^"])*)"\s*\)/m
SWIFT_DIR = File.join(ROOT, "JustGo")
VISIBLE_LITERAL_PATTERN = /
  \b(?:Text|Label|Button|Section|Picker|Toggle|ContentUnavailableView)\s*\(\s*"([^"]*[A-Za-z][^"]*)" |
  \.(?:navigationTitle|accessibilityLabel|accessibilityHint)\s*\(\s*"([^"]*[A-Za-z][^"]*)"
/x
DYNAMIC_LOCALIZATION_PATTERN = /AppLocalization\.localized\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)/
DISPLAY_PROPERTY_PATTERN = /^\s*var\s+(?:title|label|summary|displayName|description|statusText)\s*:\s*String/
RAW_RETURN_PATTERN = /\breturn\s+"([^"]*[A-Za-z][^"]*)"/

def fail_with(message)
  warn "localization validation failed: #{message}"
  exit 1
end

def parse_strings(path)
  entries = {}
  File.foreach(path).with_index(1) do |line, line_number|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("//", "/*", "*", "*/")

    match = line.match(ENTRY_PATTERN)
    fail_with("#{path}:#{line_number} is not a valid strings entry") unless match
    fail_with("#{path}:#{line_number} duplicates #{match[1].inspect}") if entries.key?(match[1])

    entries[match[1]] = match[2]
  end
  entries
end

localizations = LOCALES.to_h do |locale|
  path = File.join(ROOT, "JustGo", "Resources", "#{locale}.lproj", "Localizable.strings")
  [locale, parse_strings(path)]
end

reference_keys = localizations.fetch("en").keys.sort
LOCALES.each do |locale|
  keys = localizations.fetch(locale).keys.sort
  missing = reference_keys - keys
  extra = keys - reference_keys
  fail_with("#{locale} key mismatch; missing=#{missing.inspect} extra=#{extra.inspect}") unless missing.empty? && extra.empty?
end

reference_keys.each do |key|
  expected = localizations.fetch("en").fetch(key).scan(PLACEHOLDER_PATTERN).sort
  LOCALES.drop(1).each do |locale|
    actual = localizations.fetch(locale).fetch(key).scan(PLACEHOLDER_PATTERN).sort
    fail_with("#{locale} placeholder mismatch for #{key.inspect}") unless actual == expected
  end
end

if localizations.fetch("en") == localizations.fetch("zh-Hans")
  fail_with("English localization is an unchanged copy of Simplified Chinese")
end

LOCALES.drop(1).each do |locale|
  untranslated = localizations.fetch(locale).select { |key, value| key == value && key.match?(/[A-Za-z]/) }
  fail_with("#{locale} contains untranslated app copy: #{untranslated.keys.inspect}") unless untranslated.empty?
end

LOCALES.each do |locale|
  path = File.join(ROOT, "JustGo", "Resources", "#{locale}.lproj", "InfoPlist.strings")
  entries = parse_strings(path)
  missing = REQUIRED_INFO_KEYS - entries.keys
  fail_with("#{locale} InfoPlist.strings is missing #{missing.inspect}") unless missing.empty?
end

swift_files = Dir[File.join(SWIFT_DIR, "**", "*.swift")]
english_keys = localizations.fetch("en")
used_localization_keys = Set.new

swift_files.each do |path|
  source = File.read(path)

  source.to_enum(:scan, LITERAL_LOCALIZATION_PATTERN).each do
    match = Regexp.last_match
    key = match[1]
    line_number = source[0...match.begin(0)].count("\n") + 1
    fail_with("#{path}:#{line_number} uses missing localization key #{key.inspect}") unless english_keys.key?(key)
    used_localization_keys << key
  end

  source.to_enum(:scan, DYNAMIC_LOCALIZATION_PATTERN).each do
    match = Regexp.last_match
    line_number = source[0...match.begin(0)].count("\n") + 1
    fail_with("#{path}:#{line_number} uses dynamic localization key #{match[1]}")
  end

  property_depth = nil
  source.each_line.with_index(1) do |line, line_number|
    line.scan(VISIBLE_LITERAL_PATTERN).each do |captures|
      literal = captures.compact.first
      next if literal.include?("\\(")
      visible_text = literal.gsub(/\\\([^)]+\)/, "")
      next unless visible_text.match?(/[A-Za-z]/)
      next if visible_text.match?(/\A[\d.\s%+\/-]*(?:m|km)?\z/i)

      fail_with("#{path}:#{line_number} contains direct user-visible English literal #{literal.inspect}")
    end

    property_depth = 0 if line.match?(DISPLAY_PROPERTY_PATTERN)
    next if property_depth.nil?

    property_depth += line.count("{") - line.count("}")
    if (match = line.match(RAW_RETURN_PATTERN))
      fail_with("#{path}:#{line_number} returns raw English from a display property: #{match[1].inspect}")
    end
    property_depth = nil if property_depth <= 0
  end
end

unused_keys = reference_keys.reject { |key| used_localization_keys.include?(key) }
fail_with("Localizable.strings contains unused keys: #{unused_keys.inspect}") unless unused_keys.empty?

localization_source = File.read(File.join(SWIFT_DIR, "Core", "Localization.swift"))
unless localization_source.scan(/AppLocalization\.isChinese\s*\?\s*nil\s*:\s*name/).length == 3
  fail_with("Chinese city, station, and line alternate names must remain hidden")
end

puts "localization validation ok: locales=#{LOCALES.length} keys=#{reference_keys.length}"
