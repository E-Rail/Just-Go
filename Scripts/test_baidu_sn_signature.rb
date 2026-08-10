# frozen_string_literal: true

# Pins Baidu's SN request signature against their own published worked example.
#
# This exists because the documented algorithm is wrong by omission. The prose says: build
# "/path?query" + SK and take its MD5. Doing exactly that yields ef9cb0416260e28ab1a99ae830246e7d,
# and Baidu rejects it. The assembled string is URL-encoded a *second* time before hashing, which
# only their worked example reveals — and the failure mode is a runtime
# {"status":211,"message":"APP SN校验失败"} on a rider's phone, not a build error.
#
# The Swift implementation in Just-Go/Services/Map/BaiduMapsClient.swift must match this byte for
# byte. Both are checked here: the algorithm itself, and that the Swift source still spells out the
# two rules that are easy to "tidy" into breakage — encode twice, and space becomes "+" not "%20".

require "cgi"
require "digest/md5"
require "minitest/autorun"

ROOT = File.expand_path("..", __dir__)

class BaiduSignatureTest < Minitest::Test
  # From Baidu's own documentation.
  PATH = "/geocoder/v2/"
  QUERY = "address=%E7%99%BE%E5%BA%A6%E5%A4%A7%E5%8E%A6&output=json&ak=yourak"
  SECRET_KEY = "yoursk"
  EXPECTED = "7de5a22212ffaa9e326444c75a58f9a0"

  def signature(path, query, secret_key)
    Digest::MD5.hexdigest(CGI.escape("#{path}?#{query}#{secret_key}"))
  end

  def test_matches_baidus_published_vector
    assert_equal EXPECTED, signature(PATH, QUERY, SECRET_KEY)
  end

  def test_single_encoding_is_the_wrong_answer
    # Guards the comment as much as the code: if someone "simplifies" away the second encode, this
    # is the value they will get, and it is not a signature Baidu accepts.
    naive = Digest::MD5.hexdigest("#{PATH}?#{QUERY}#{SECRET_KEY}")
    refute_equal EXPECTED, naive
  end

  def test_swift_client_still_encodes_twice_and_uses_plus_for_space
    source = File.read(File.join(ROOT, "Just-Go/Services/Map/BaiduMapsClient.swift"), encoding: "UTF-8")

    assert_includes source, "urlEncoded(assembled)",
                    "the assembled path+query+SK must be URL-encoded again before hashing"
    assert_includes source, 'encoded.append("+")',
                    "PHP urlencode maps space to '+'; %20 produces a signature Baidu rejects"
    assert_includes source, "Insecure.MD5.hash",
                    "the signature is an MD5 digest"
  end

  def test_signing_is_optional_so_an_ip_whitelist_key_still_works
    source = File.read(File.join(ROOT, "Just-Go/Services/Map/BaiduMapsClient.swift"), encoding: "UTF-8")

    # The console is on IP 白名单 today, which issues no SK. Requests must go out unsigned in that
    # configuration and start signing the moment an SK appears, with no other change.
    assert_includes source, "if let secretKey = configuration.secretKey",
                    "signing must be conditional on an SK being present"
  end
end
