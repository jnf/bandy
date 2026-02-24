require 'minitest/autorun'
require 'logger'
require 'json'
require 'httparty'
require 'nokogiri'

DEBUG = false unless defined?(DEBUG)

require_relative '../api/baseapi'

# --- Fake HTTP client ---
# Responds to .get and .post like HTTParty class methods.
# Configure with a block or a canned response.
class FakeHTTP
  attr_reader :last_path, :last_opts

  def initialize(&handler)
    @handler = handler
  end

  def get(path, opts = {})
    @last_path = path
    @last_opts = opts
    @handler.call(:get, path, opts)
  end

  def post(path, opts = {})
    @last_path = path
    @last_opts = opts
    @handler.call(:post, path, opts)
  end
end

# --- CollectionSummary ---

class TestCollectionSummary < Minitest::Test
  def test_successful_fetch_returns_true_and_response
    response = { "fan_id" => "42", "collection_summary" => {} }
    client = FakeHTTP.new { |*| response }
    cs = API::CollectionSummary.new(http_client: client)

    happy, deets = cs.fetch
    assert happy
    assert_equal "42", deets["fan_id"]
  end

  def test_failed_fetch_returns_false_and_error
    client = FakeHTTP.new { |*| raise StandardError, "connection refused" }
    cs = API::CollectionSummary.new(http_client: client)

    happy, deets = cs.fetch
    refute happy
    assert_kind_of StandardError, deets
    assert_match(/connection refused/, deets.message)
  end
end

# --- CollectionItems ---

class TestCollectionItems < Minitest::Test
  def test_default_token_is_tomorrow
    tomorrow = Time.now.to_i + 86_400
    client = FakeHTTP.new { |*| {} }
    ci = API::CollectionItems.new(fan_id: "42", http_client: client)

    # Token format: "timestamp:0:a::"
    token_timestamp = ci.older_than_token.split(":").first.to_i
    assert_in_delta tomorrow, token_timestamp, 2
  end

  def test_explicit_fan_id_is_used
    client = FakeHTTP.new { |*| {} }
    ci = API::CollectionItems.new(fan_id: "1313", http_client: client)
    assert_equal "1313", ci.fan_id
  end

  def test_pagination_advances_token
    response = {
      "more_available" => true,
      "items" => [
        { "token" => "111:0:a::" },
        { "token" => "222:0:a::" }
      ]
    }
    client = FakeHTTP.new { |*| response }
    ci = API::CollectionItems.new(fan_id: "42", http_client: client)

    ci.fetch
    assert_equal "222:0:a::", ci.older_than_token
  end

  def test_pagination_clears_token_when_no_more
    response = {
      "more_available" => false,
      "items" => [{ "token" => "111:0:a::" }]
    }
    client = FakeHTTP.new { |*| response }
    ci = API::CollectionItems.new(fan_id: "42", http_client: client)

    ci.fetch
    assert_equal false, ci.older_than_token
  end

  def test_fetch_returns_true_and_response
    response = { "more_available" => false, "items" => [] }
    client = FakeHTTP.new { |*| response }
    ci = API::CollectionItems.new(fan_id: "42", http_client: client)

    happy, deets = ci.fetch
    assert happy
    assert_equal response, deets
  end

  def test_fetch_error_returns_false_and_error
    client = FakeHTTP.new { |*| raise StandardError, "timeout" }
    ci = API::CollectionItems.new(fan_id: "42", http_client: client)

    happy, deets = ci.fetch
    refute happy
    assert_kind_of StandardError, deets
  end
end

# --- PageData ---

class TestPageData < Minitest::Test
  def pagedata_html(blob)
    "<html><body><div id=\"pagedata\" data-blob='#{blob.to_json}'></div></body></html>"
  end

  def fake_response(body)
    obj = Object.new
    obj.define_singleton_method(:body) { body }
    obj
  end

  def test_parses_pagedata_from_html
    blob = { "digital_items" => [{ "name" => "Test Album" }] }
    client = FakeHTTP.new { |*| fake_response(pagedata_html(blob)) }
    pd = API::PageData.new(path: "/some/page", http_client: client)

    happy, deets = pd.fetch
    assert happy
    assert_equal "Test Album", deets["digital_items"][0]["name"]
  end

  def test_missing_pagedata_returns_false_and_error
    client = FakeHTTP.new { |*| fake_response("<html><body></body></html>") }
    pd = API::PageData.new(path: "/some/page", http_client: client)

    happy, deets = pd.fetch
    refute happy
    assert_kind_of StandardError, deets
  end

  def test_uses_injected_path
    client = FakeHTTP.new { |*, opts| fake_response("<html></html>") }
    pd = API::PageData.new(path: "/redownload/abc123", http_client: client)
    pd.fetch
    assert_equal "/redownload/abc123", client.last_path
  end
end
