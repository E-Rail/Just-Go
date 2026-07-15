#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/oss_data_validators"

begin
  require_history = !ARGV.delete("--history").nil?
  unless ARGV.empty?
    raise OSSDataValidators::ValidationError, "unknown arguments: #{ARGV.join(", ")}"
  end
  validator = OSSDataValidators::RightsValidator.new
  validator.validate!
  validator.validate_history! if require_history
  puts "data-rights validation ok: licenses=#{OSSDataValidators::SUPPORTED_LICENSES.length} sources=4 media=2 history=#{require_history ? "clean" : "not_checked"}"
rescue OSSDataValidators::ValidationError => error
  warn "data-rights validation failed: #{error.message}"
  exit 1
end
