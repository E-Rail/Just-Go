#!/usr/bin/env ruby
# frozen_string_literal: true

ROOT = File.expand_path("..", __dir__)
LOCALES = %w[en zh-Hans zh-Hant].freeze
REQUIRED_INFO_KEYS = %w[
  NSLocationWhenInUseUsageDescription
  NSLocationAlwaysAndWhenInUseUsageDescription
].freeze
ENTRY_PATTERN = /^\s*"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";\s*$/
PLACEHOLDER_PATTERN = /%(?:\d+\$)?[@dfius]/

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

LOCALES.each do |locale|
  path = File.join(ROOT, "JustGo", "Resources", "#{locale}.lproj", "InfoPlist.strings")
  entries = parse_strings(path)
  missing = REQUIRED_INFO_KEYS - entries.keys
  fail_with("#{locale} InfoPlist.strings is missing #{missing.inspect}") unless missing.empty?
end

puts "localization validation ok: locales=#{LOCALES.length} keys=#{reference_keys.length}"
