# frozen_string_literal: true

# Pins how the app rations a provider allowance it cannot see.
#
# The free individual tier publishes these per-day ceilings, and they are per *account*, shared
# across every rider using the app rather than per device:
#
#   /place/v2/search        100
#   /reverse_geocoding/v3/  300
#   route planning        5,000
#
# 100 place searches a day is roughly five riders. The two endpoints this app shipped first are the
# two most starved, and the one with fifty times the headroom is the one that carries the fare, the
# taxi estimate, the first and last train and the transfer corridors. So: spend routing freely,
# ration search, and make the aftermath of exhaustion a local refusal rather than a round trip to be
# told 302 每日配额超限.
#
# None of this *enforces* the account quota, and it is not meant to. It stops one device spending
# the whole day's allowance in a sitting. The real fix is an enterprise account or a backend, and
# that is a decision outside this repo.

require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)
CLIENT = File.read(File.join(ROOT, "Just-Go/Services/Map/BaiduMapsClient.swift"), encoding: "UTF-8")
COMPOSITE = File.read(
  File.join(ROOT, "Just-Go/Services/Map/BaiduPlaceSearchProvider.swift"), encoding: "UTF-8"
)

class RequestBudgetTest < Minitest::Test
  def ceiling(path)
    match = CLIENT[/"#{Regexp.escape(path)}":\s*(\d+)/, 1]
    refute_nil match, "no budget declared for #{path}"
    match.to_i
  end

  def test_search_is_rationed_far_harder_than_routing
    # The ceilings must stay lopsided in the same direction as the allowance itself. Equalising them
    # would starve the endpoint every rider-facing fact now comes from.
    assert_operator ceiling("/direction/v2/transit"), :>, ceiling("/place/v2/search") * 4
    assert_operator ceiling("/reverse_geocoding/v3/"), :<, ceiling("/direction/v2/transit")
  end

  def test_every_rationed_ceiling_is_positive
    %w[/place/v2/search /reverse_geocoding/v3/ /direction/v2/transit /direction/v2/riding].each do |path|
      assert_operator ceiling(path), :>, 0, "#{path} must allow at least one call"
    end
  end

  def test_exhaustion_costs_no_round_trip
    # Checked before the request is built, so a spent budget is free rather than a timeout.
    budget_index = CLIENT.index("RequestBudget.ceilings[path]")
    request_index = CLIENT.index("session.data(from: url)")

    refute_nil budget_index
    refute_nil request_index
    assert_operator budget_index, :<, request_index,
                    "the budget must be checked before the network call, not after"
  end

  def test_exhaustion_is_a_throw_so_callers_already_handle_it
    # Every caller treats a throw as "no answer" and falls back, so this needs no new handling: it
    # degrades the app to exactly what it is with no key.
    #
    # The behaviour itself is exercised at runtime by Scripts/test_baidu_request_gate.sh, which
    # spends a whole ceiling against a stub URLProtocol and counts what reaches the wire. This
    # stays a source check because it is about the *shape* callers depend on.
    assert_includes CLIENT, "case budgetExhausted(path: String)"
    assert_includes CLIENT, "BaiduMapsError.budgetExhausted(path: path)"
    assert_match(/let error = BaiduMapsError\.budgetExhausted.*\n.*record\(error.*\n.*throw error/, CLIENT,
                 "an exhausted budget must be recorded as well as thrown, or nobody can tell which limit was hit")
  end

  def test_the_rate_gate_stays_inside_the_published_free_tier
    # 3 QPS, per account, shared by every rider using the app. Both halves matter: concurrency
    # alone does not bound a rate, because two slots with instant responses is unlimited
    # throughput. Measured for real in Scripts/test_baidu_request_gate.sh.
    concurrent = CLIENT[/maximumConcurrentRequests = (\d+)/, 1]
    refute_nil concurrent, "no concurrency ceiling declared"
    assert_operator concurrent.to_i, :<=, 3
    assert_operator concurrent.to_i, :>=, 1

    spacing = CLIENT[/minimumRequestSpacing = Duration\.milliseconds\((\d+)\)/, 1]
    refute_nil spacing, "no request spacing declared"
    assert_operator spacing.to_i, :>=, 334, "a gap under 1/3 s lets a burst exceed 3 QPS"
  end

  def test_identical_requests_in_flight_are_joined
    # The per-service caches check on the way in and write on the way out, so two identical plans
    # starting together both miss and both spend a call.
    assert_includes CLIENT, "private var coalescing: [String: Task<Data, Error>] = [:]"
    coalesce_index = CLIENT.index("if let existing = coalescing[key]")
    budget_index = CLIENT.index("if let ceiling = RequestBudget.ceilings[path]")
    refute_nil coalesce_index
    refute_nil budget_index
    assert_operator coalesce_index, :<, budget_index,
                    "a joined request must cost no budget, so coalescing comes first"
  end
end

class TypingCostsNothingTest < Minitest::Test
  VIEW = File.read(File.join(ROOT, "Just-Go/Views/Search/StationSearchView.swift"), encoding: "UTF-8")
  MODEL = File.read(
    File.join(ROOT, "Just-Go/ViewModels/Search/StationSearchViewModel.swift"), encoding: "UTF-8"
  )
  SERVICE = File.read(
    File.join(ROOT, "Just-Go/Services/Transit/StationSearchService.swift"), encoding: "UTF-8"
  )

  def test_a_keystroke_never_reaches_the_place_provider
    # 100 place searches a day for the whole account is about five riders, and this page used to
    # spend two of them on every typing pause: one at limit 20 through the view model and one at
    # limit 12 through the view. Typing is now answered entirely from the bundled station index.
    assert_includes MODEL, "await self?.search(includingPlaces: false)"
    assert_includes SERVICE, "guard includingPlaces else { return bundledMatches }"
    assert_includes VIEW, ".onSubmit { searchOnline() }"

    setter = VIEW[/set: \{ newValue in(.*?)\n            \)\)/m, 1]
    refute_nil setter, "could not find the search field's setter"
    refute_includes setter, "schedulePlaceSearch(",
                    "typing must not start a place search"
  end

  def test_the_online_search_is_reachable_without_a_keyboard
    # A capability that only answers the return key is one most riders never find.
    assert_includes VIEW, "private var searchOnlineRow: some View"
    assert_includes VIEW, "private func searchOnline() {"
  end
end

class SearchRoutingPolicyTest < Minitest::Test
  def test_latin_queries_never_spend_a_search
    # Baidu was brought in for Chinese place names, where Apple returned unrelated places and no
    # station. A Latin query has no such problem and does not justify one of the day's hundred.
    assert_includes COMPOSITE, "Self.containsCJK(keyword)"
    assert_includes COMPOSITE, "static func containsCJK(_ text: String) -> Bool"
    assert_includes COMPOSITE, "(0x4E00...0x9FFF)", "CJK Unified Ideographs is the main block"
  end

  def test_reverse_geocoding_asks_apple_first
    # The opposite order from place search, deliberately. Turning a coordinate into a street address
    # is not the thing Apple is weak at, and this is the call the app makes most casually.
    apple_index = COMPOSITE.index("let place = try await appleMaps.reverseGeocode")
    baidu_index = COMPOSITE.index("return try await baidu.reverseGeocode")

    refute_nil apple_index
    refute_nil baidu_index
    assert_operator apple_index, :<, baidu_index,
                    "Apple must be tried before spending one of 300 daily reverse geocodes"
  end

  def test_place_search_still_asks_baidu_first_for_chinese
    # The inverse of the rule above, and the reason the provider exists at all. Do not "tidy" these
    # two methods into the same order.
    baidu_index = COMPOSITE.index("try await baidu.searchPlaces")
    apple_index = COMPOSITE.index("return try await appleMaps.searchPlaces")

    assert_operator baidu_index, :<, apple_index,
                    "a Chinese place query must reach Baidu before Apple"
  end
end
