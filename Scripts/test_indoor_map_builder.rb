#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "build_indoor_maps"

class IndoorMapBuilderTest < Minitest::Test
  def test_linear_pattern_resolves_forward_and_backward
    line = { "servicePatterns" => [%w[a b c d]] }

    assert_equal "c", immediate_neighbor_toward(line, "b", "d")
    assert_equal "b", immediate_neighbor_toward(line, "c", "a")
  end

  def test_loop_pattern_chooses_shorter_direction_and_wraps
    line = { "servicePatterns" => [%w[a b c d e a]] }

    assert_equal "b", immediate_neighbor_toward(line, "a", "c")
    assert_equal "e", immediate_neighbor_toward(line, "a", "e")
    assert_equal "a", immediate_neighbor_toward(line, "e", "b")
  end

  def test_loop_tie_follows_service_pattern_order
    line = { "servicePatterns" => [%w[a b c d a]] }

    assert_equal "b", immediate_neighbor_toward(line, "a", "c")
  end

  def test_missing_or_identical_stations_return_nil
    line = { "servicePatterns" => [%w[a b c]] }

    assert_nil immediate_neighbor_toward(line, "missing", "c")
    assert_nil immediate_neighbor_toward(line, "a", "missing")
    assert_nil immediate_neighbor_toward(line, "b", "b")
    assert_nil immediate_neighbor_toward(line, nil, "b")
  end

  def test_degenerate_patterns_return_nil
    assert_nil immediate_neighbor_toward({ "servicePatterns" => [] }, "a", "b")
    assert_nil immediate_neighbor_toward({ "servicePatterns" => [[]] }, "a", "b")
    assert_nil immediate_neighbor_toward({ "servicePatterns" => [["a"]] }, "a", "b")
    assert_nil immediate_neighbor_toward({ "servicePatterns" => [%w[a a]] }, "a", "b")
  end
end
