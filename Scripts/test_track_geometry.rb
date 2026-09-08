# frozen_string_literal: true

# Pins how much of the bundled track this app can actually draw, and how much of what it draws
# holds together.
#
# `MetroTrackGeometry` slices a line's OSM ways into one polyline per hop, and
# `BundledMetroRouteProvider+RouteAssembly` concatenates a leg's hops into a single `MKPolyline`.
# Two numbers decide whether a drawn route is honest:
#
#   1. **Chord hops** — pairs with no usable stretch of track between them, drawn as a straight
#      line. Every one of these is a rider being shown a shape the train does not follow.
#   2. **Join gaps** — the distance between where hop *i* ends and hop *i+1* begins. `MKPolyline`
#      draws a straight segment across any gap, so a discontinuous join is the same lie, arriving
#      in the middle of a leg where it is harder to notice.
#
# Both used to be far worse than anyone had counted. Resolving each hop independently let two
# consecutive hops put their shared station on two different ways: 2,012 of 7,612 joins were
# discontinuous, 26 by more than 50 m, the worst an 823 m leap through 三重國小. Carrying an anchor
# forward greedily fixed most of that and could not fix the rest, because a greedy chain commits to
# hop *i* before it can see what hop *i+1* needs — 17 visible breaks survived, the worst 772 m at
# 大橋頭. Solving the whole pattern at once takes that to zero.
#
# This file is a **reference implementation** of the shipped resolver, run over the real packs. It
# exists because there is no Xcode test target and no other way to hold these numbers still. It has
# to be kept in step with `MetroTrackGeometry` by hand; when the Swift changes, change this and
# say what moved. Distances here are haversine where Swift uses `CLLocation`, so the counts can
# differ by one or two — the pins carry a little headroom for that and no more.

require "minitest/autorun"
require "json"

ROOT = File.expand_path("..", __dir__)
NETWORKS = File.join(ROOT, "Just-Go/Resources/MetroNetworks")

module TrackGeometry
  EARTH = 6_371_008.8
  CANDIDATE_DISTANCE_CAP = 900.0
  CANDIDATE_LIMIT = 4
  CANDIDATE_SEPARATION = 100.0
  SEAM_WEIGHT = 120.0
  SEED_SEPARATION = 25.0
  STATION_CANDIDATE_LIMIT = 6
  CHAIN_BEAM = 48

  module_function

  def distance(a, b)
    lat1 = a[0] * Math::PI / 180
    lat2 = b[0] * Math::PI / 180
    h = Math.sin((lat2 - lat1) / 2)**2 +
        Math.cos(lat1) * Math.cos(lat2) * Math.sin(((b[1] - a[1]) * Math::PI / 180) / 2)**2
    2 * EARTH * Math.asin([1.0, Math.sqrt(h)].min)
  end

  # Every local minimum of the station-to-track distance, nearest first, one per pass of the way.
  def projections(coordinate, points, cumulative)
    return [] if points.size < 2

    per_segment = []
    (0...(points.size - 1)).each do |i|
      a = points[i]
      b = points[i + 1]
      m_lon = 111_320.0 * Math.cos(a[0] * Math::PI / 180)
      m_lat = 110_540.0
      ax = a[1] * m_lon
      ay = a[0] * m_lat
      bx = b[1] * m_lon
      by = b[0] * m_lat
      px = coordinate[1] * m_lon
      py = coordinate[0] * m_lat
      dx = bx - ax
      dy = by - ay
      length2 = (dx * dx) + (dy * dy)
      t = length2.zero? ? 0.0 : [1.0, [0.0, (((px - ax) * dx) + ((py - ay) * dy)) / length2].max].min
      projected = [(ay + (t * dy)) / m_lat, (ax + (t * dx)) / m_lon]
      per_segment << {
        point: projected,
        distance: distance(coordinate, projected),
        offset: cumulative[i] + (t * (cumulative[i + 1] - cumulative[i]))
      }
    end

    minima = []
    per_segment.each_with_index do |candidate, i|
      previous = i.positive? ? per_segment[i - 1][:distance] : Float::INFINITY
      following = i < per_segment.size - 1 ? per_segment[i + 1][:distance] : Float::INFINITY
      next unless candidate[:distance] <= previous && candidate[:distance] <= following
      next unless candidate[:distance] <= CANDIDATE_DISTANCE_CAP

      minima << candidate
    end
    if minima.empty?
      nearest = per_segment.min_by { |c| c[:distance] }
      minima = [nearest] if nearest && nearest[:distance] <= CANDIDATE_DISTANCE_CAP
    end

    kept = []
    minima.sort_by { |c| c[:distance] }.each do |candidate|
      next if kept.any? { |k| (k[:offset] - candidate[:offset]).abs < CANDIDATE_SEPARATION }

      kept << candidate
      break if kept.size == CANDIDATE_LIMIT
    end
    kept
  end

  def slice(points, cumulative, from, to)
    total = cumulative[-1]
    ring = points.size >= 3 && distance(points[0], points[-1]) < 5
    low = [from[:offset], to[:offset]].min
    high = [from[:offset], to[:offset]].max
    reversed = from[:offset] > to[:offset]
    low_point = reversed ? to[:point] : from[:point]
    high_point = reversed ? from[:point] : to[:point]

    if !ring || (high - low) <= total - (high - low)
      result = [low_point]
      points.each_index { |i| result << points[i] if cumulative[i] > low && cumulative[i] < high }
      result << high_point
    else
      result = [high_point]
      points.each_index { |i| result << points[i] if cumulative[i] > high }
      points.each_index do |i|
        next unless cumulative[i] < low
        next if result.last && distance(result.last, points[i]) < 1

        result << points[i]
      end
      result << low_point
      result.reverse!
    end
    result.reverse! if reversed
    result
  end

  def arc_length(coordinates)
    total = 0.0
    (1...coordinates.size).each { |i| total += distance(coordinates[i - 1], coordinates[i]) }
    total
  end

  def deduplicated(coordinates)
    joined = []
    coordinates.each { |p| joined << p if joined.empty? || distance(joined.last, p) >= 1 }
    joined
  end

  def prepare(paths)
    paths.map do |points|
      next nil if points.size < 2

      cumulative = [0.0]
      (1...points.size).each { |i| cumulative << cumulative[i - 1] + distance(points[i - 1], points[i]) }
      [points, cumulative]
    end.compact
  end

  # Where one station could sit on each of the line's ways. Every way's view of the station seeds
  # every other way's list, because the point where two ways meet is a projection of a projection.
  def station_candidates(coordinate, prepared)
    per_path = prepared.map { |points, cumulative| projections(coordinate, points, cumulative) }
    seeds = []
    per_path.flatten.each do |candidate|
      next if seeds.any? { |s| distance(s, candidate[:point]) < SEED_SEPARATION }

      seeds << candidate[:point]
    end

    per_path.each_with_index do |list, path_index|
      points, cumulative = prepared[path_index]
      seeds.each do |seed|
        projections(seed, points, cumulative).each do |carried|
          # Both tests, always. Offset alone discards the seam candidate at a branch; position
          # alone merges a ring's start and end, which are one point at opposite offsets.
          next if list.any? do |existing|
            (existing[:offset] - carried[:offset]).abs < CANDIDATE_SEPARATION &&
              distance(existing[:point], carried[:point]) < 5
          end

          d = distance(coordinate, carried[:point])
          next if d > CANDIDATE_DISTANCE_CAP

          list << { point: carried[:point], offset: carried[:offset], distance: d }
        end
      end
      per_path[path_index] = list.sort_by { |c| c[:distance] }.first(STATION_CANDIDATE_LIMIT)
    end
    per_path
  end

  def chord_ends(coordinate, per_path)
    ends = [{ point: coordinate, distance: 0.0, offset: 0.0 }]
    per_path.flatten.each do |candidate|
      next if ends.any? { |e| distance(e[:point], candidate[:point]) < SEED_SEPARATION }

      ends << candidate
    end
    ends
  end

  # Every way this one hop could be drawn along, with what drawing it that way costs.
  def hop_candidates(from, to, from_per_path, to_per_path, prepared)
    separation = distance(from, to)
    ceiling = [2.5 * separation, separation + 1_500].max
    floor = 0.75 * separation

    track = []
    prepared.each_with_index do |(points, cumulative), path_index|
      heads = from_per_path[path_index]
      tails = to_per_path[path_index]
      next if heads.empty? || tails.empty?

      heads.each do |f|
        tails.each do |t|
          candidate = slice(points, cumulative, f, t)
          next if candidate.size < 2

          arc = arc_length(candidate)
          next unless arc <= ceiling
          next unless arc + f[:distance] + t[:distance] >= floor

          joined = deduplicated(candidate)
          next if joined.size < 2

          track << { head: joined.first, tail: joined.last, geometry: joined,
                     cost: arc + (3 * (f[:distance] + t[:distance])) }
        end
      end
    end
    return [track, :track] unless track.empty?

    # Nothing on this line reaches both stations, so the hop is a straight line and the only
    # question left is where to draw it from — every point either station could sit at is offered,
    # so the chain can begin it exactly where its known track ran out.
    chords = []
    chord_ends(from, from_per_path).each do |f|
      chord_ends(to, to_per_path).each do |t|
        chords << { head: f[:point], tail: t[:point], geometry: [f[:point], t[:point]],
                    cost: distance(f[:point], t[:point]) + (3 * (f[:distance] + t[:distance])) }
      end
    end
    [chords, :chord]
  end

  # Shortest path through a layered graph: one layer per hop, one node per way the hop could be
  # drawn along, edges weighted by the gap they would leave at the station two hops share.
  def resolve(coordinates, prepared)
    per_station = coordinates.map { |c| station_candidates(c, prepared) }
    kinds = []
    layers = []

    coordinates.each_cons(2).with_index do |(from, to), index|
      candidates, kind = hop_candidates(from, to, per_station[index], per_station[index + 1], prepared)
      kinds << kind
      previous = layers.last
      layer = candidates.map do |candidate|
        if previous.nil?
          { cost: candidate[:cost], tail: candidate[:tail], geometry: candidate[:geometry], back: 0 }
        else
          best_cost = Float::INFINITY
          best_index = 0
          previous.each_with_index do |state, state_index|
            reached = state[:cost] + (SEAM_WEIGHT * distance(state[:tail], candidate[:head]))
            if reached < best_cost
              best_cost = reached
              best_index = state_index
            end
          end
          { cost: best_cost + candidate[:cost], tail: candidate[:tail],
            geometry: candidate[:geometry], back: best_index }
        end
      end
      layer = layer.sort_by { |s| s[:cost] }.first(CHAIN_BEAM) if layer.size > CHAIN_BEAM
      layers << layer
    end

    chain = Array.new(layers.size) { [] }
    state_index = layers.last.each_index.min_by { |i| layers.last[i][:cost] }
    (layers.size - 1).downto(0) do |layer_index|
      state = layers[layer_index][state_index]
      chain[layer_index] = state[:geometry]
      state_index = state[:back]
    end
    chain.each_with_index.map { |geometry, i| [geometry, kinds[i]] }
  end
end

# Walks every bundled pack once and totals both measures.
def measure_bundled_track
  hops = 0
  chords = 0
  gaps = []

  Dir[File.join(NETWORKS, "*.json")].sort.each do |file|
    pack = JSON.parse(File.read(file, encoding: "UTF-8"))
    stations = {}
    pack["stations"].each { |s| stations[s["id"]] = [s["latitude"], s["longitude"]] }

    pack["lines"].each do |line|
      paths = (line["paths"] || []).map { |path| path.map { |c| [c["latitude"], c["longitude"]] } }
      next if paths.empty?

      prepared = TrackGeometry.prepare(paths)
      next if prepared.empty?

      (line["servicePatterns"] || []).each do |pattern|
        coordinates = pattern.map { |id| stations[id] }
        next if coordinates.any?(&:nil?) || coordinates.size < 2

        previous = nil
        TrackGeometry.resolve(coordinates, prepared).each do |geometry, kind|
          hops += 1
          chords += 1 if kind == :chord
          gaps << TrackGeometry.distance(previous, geometry.first) if previous
          previous = geometry.last
        end
      end
    end
  end

  { hops: hops, chords: chords, gaps: gaps }
end

MEASURED = measure_bundled_track

class TrackGeometryTest < Minitest::Test
  def test_the_pack_set_has_not_silently_shrunk
    # The denominator for everything below. If a pack is added or dropped this moves, and the
    # counts underneath it have to be re-read rather than merely re-passed.
    assert_equal 8_015, MEASURED[:hops], "bundled hop count changed; re-read the pins below"
  end

  def test_almost_every_hop_draws_real_track
    # 6 with the shipped resolver, in 4 distinct pairs: 南口 → 八达岭 and 康庄 → 沙城 on the S2
    # line, 清河 → 昌平北 on 怀密线, and 馬場 → 沙田 across the East Rail racecourse spur. No way on
    # any of those lines reaches both stations, so each is drawn as a straight line — the honest
    # rendering of "there is no track here in the data", not a bug to be papered over.
    assert_operator MEASURED[:chords], :<=, 8,
                    "more hops lost their track geometry (was 6 of 8,015)"
  end

  def test_legs_hold_together_at_their_joins
    gaps = MEASURED[:gaps]
    # A leg is one polyline, so a join gap is drawn as a straight segment through the station.
    # Under 1 m is a rounding artefact of two projections onto the same point.
    assert_operator gaps.count { |g| g > 1 }, :<=, 30,
                    "more joins came apart (was 19 of 7,612)"
    # The visible ones. This is the number the whole design exists for and it is zero: solving a
    # pattern as a chain rather than hop by hop means a break is only ever accepted when no chain
    # avoids it, and across the bundled data none has to be.
    assert_equal 0, gaps.count { |g| g > 50 },
                 "a join broke visibly; the chain solver accepted a seam it should have routed around"
  end

  def test_the_worst_join_has_not_got_worse
    # 13.5 m, which is a way-to-way seam in the source data and not a chosen discontinuity. The
    # bound is set below the 50 m the test above calls visible, so this fails first.
    assert_operator MEASURED[:gaps].max, :<=, 40,
                    "the widest join gap grew (was 13.5 m)"
  end
end
