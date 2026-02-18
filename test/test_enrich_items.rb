require 'minitest/autorun'
require 'tmpdir'
require 'pstore'
require 'logger'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/enrich_items'

class TestEnrichItems < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = PStore.new(File.join(@tmpdir, "test.pstore"))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  def seed_store(items, fan_id: "42")
    @store.transaction do
      @store[:items] = items
      @store[:config] = { fan_id: fan_id }
    end
  end

  def stored_items
    @store.transaction { @store.fetch(:items, {}) }
  end

  # Builds the hash shape that update_store reads from the API response.
  def api_item(tralbum_type: "a", tralbum_id: 123, sale_item_type: "a", sale_item_id: 456,
               token: "tok-1", is_preorder: false)
    {
      "tralbum_type" => tralbum_type,
      "tralbum_id" => tralbum_id,
      "sale_item_type" => sale_item_type,
      "sale_item_id" => sale_item_id,
      "token" => token,
      "is_preorder" => is_preorder,
      "band_name" => "Test Artist",
      "album_title" => "Test Album"
    }
  end

  def api_response(items:, more_available: false)
    redownload_urls = items.each_with_object({}) do |i, h|
      h["#{i["sale_item_type"]}#{i["sale_item_id"]}"] = "https://example.com/dl/#{i["tralbum_id"]}"
    end
    { "items" => items, "redownload_urls" => redownload_urls, "more_available" => more_available }
  end

  def fake_api(response)
    api = Object.new
    api.define_singleton_method(:fetch) { [true, response] }
    api
  end

  def null_api
    fake_api(api_response(items: []))
  end

  def enrich(hidden_items_api: null_api, collection_items_api: null_api)
    EnrichItems.new(store: @store, hidden_items_api: hidden_items_api, collection_items_api: collection_items_api).run
  end

  # --- Tests ---

  def test_seen_item_enriched_to_ready
    seed_store({ "a123" => { state: :seen } })
    item = api_item(tralbum_type: "a", tralbum_id: 123, sale_item_type: "a", sale_item_id: 456, is_preorder: false)
    enrich(hidden_items_api: fake_api(api_response(items: [item])))

    result = stored_items["a123"]
    assert_equal :ready, result[:state]
    assert_equal "tok-1", result[:token]
    assert_equal "https://example.com/dl/123", result[:redownload_url]
  end

  def test_seen_item_enriched_to_preorder
    seed_store({ "a123" => { state: :seen } })
    item = api_item(tralbum_type: "a", tralbum_id: 123, is_preorder: true)
    enrich(hidden_items_api: fake_api(api_response(items: [item])))

    assert_equal :preorder, stored_items["a123"][:state]
  end

  def test_preorder_item_becomes_ready_when_released
    seed_store({ "a123" => { state: :preorder } })
    item = api_item(tralbum_type: "a", tralbum_id: 123, is_preorder: false)
    # Both APIs get the same response; whichever processes "a123" first makes it :ready,
    # the second call sees :ready and skips it (line 50 guard).
    response = api_response(items: [item])
    enrich(hidden_items_api: fake_api(response), collection_items_api: fake_api(response))

    assert_equal :ready, stored_items["a123"][:state]
  end

  def test_known_preorder_still_preorder_is_skipped
    seed_store({ "a123" => { state: :preorder } })
    item = api_item(tralbum_type: "a", tralbum_id: 123, is_preorder: true)
    response = api_response(items: [item])
    enrich(hidden_items_api: fake_api(response), collection_items_api: fake_api(response))

    assert_equal :preorder, stored_items["a123"][:state]
  end

  def test_api_item_not_in_store_is_skipped
    seed_store({ "a123" => { state: :seen } })
    unknown = api_item(tralbum_type: "a", tralbum_id: 999)  # key "a999" not in store
    known   = api_item(tralbum_type: "a", tralbum_id: 123)
    enrich(hidden_items_api: fake_api(api_response(items: [unknown, known])))

    assert_equal :ready, stored_items["a123"][:state]
    refute stored_items.key?("a999")
  end

  def test_non_seen_item_not_overwritten
    seed_store({ "a123" => { state: :ready, token: "original-token" } })
    item = api_item(tralbum_type: "a", tralbum_id: 123, token: "new-token")
    enrich(hidden_items_api: fake_api(api_response(items: [item])))

    assert_equal :ready, stored_items["a123"][:state]
    assert_equal "original-token", stored_items["a123"][:token]
  end

  def test_pagination_fetches_until_more_available_false
    seed_store({ "a123" => { state: :seen }, "b456" => { state: :seen } })

    call_count = 0
    pages = [
      api_response(items: [api_item(tralbum_type: "a", tralbum_id: 123)], more_available: true),
      api_response(items: [api_item(tralbum_type: "b", tralbum_id: 456)], more_available: false)
    ]
    paginating_api = Object.new
    paginating_api.define_singleton_method(:fetch) { call_count += 1; [true, pages.shift] }

    enrich(hidden_items_api: paginating_api)

    assert_equal 2, call_count
    assert_equal :ready, stored_items["a123"][:state]
    assert_equal :ready, stored_items["b456"][:state]
  end
end
