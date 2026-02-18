require 'minitest/autorun'
require 'tmpdir'
require 'pstore'
require 'logger'
require 'date'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/sync_collection'

class TestSyncCollection < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = PStore.new(File.join(@tmpdir, "test.pstore"))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  def fake_api(response)
    api = Object.new
    api.define_singleton_method(:fetch) { response }
    api
  end

  def api_response(tralbum_lookup:, fan_id: "42")
    [true, {
      "fan_id" => fan_id,
      "collection_summary" => { "tralbum_lookup" => tralbum_lookup }
    }]
  end

  def stored_items
    @store.transaction { @store.fetch(:items, {}) }
  end

  def stored_fan_id
    @store.transaction { @store.fetch(:config, {})[:fan_id] }
  end

  # --- Tests ---

  def test_new_purchased_item_written_as_seen
    api = fake_api(api_response(tralbum_lookup: {
      "a12345" => { "purchased" => "2024-01-15 12:00:00 UTC" }
    }))

    SyncCollection.new(store: @store, collection_summary_api: api).run

    item = stored_items["a12345"]
    assert_equal :seen, item[:state]
    assert_kind_of Integer, item[:purchased]
  end

  def test_purchased_timestamp_parsed_correctly
    api = fake_api(api_response(tralbum_lookup: {
      "a12345" => { "purchased" => "2024-01-15 12:00:00 UTC" }
    }))

    SyncCollection.new(store: @store, collection_summary_api: api).run

    expected = DateTime.parse("2024-01-15 12:00:00 UTC").to_time.to_i
    assert_equal expected, stored_items["a12345"][:purchased]
  end

  def test_wishlist_item_not_written_to_store
    api = fake_api(api_response(tralbum_lookup: {
      "a12345" => { "purchased" => "2024-01-15 12:00:00 UTC" },
      "b67890" => { "purchased" => nil }
    }))

    SyncCollection.new(store: @store, collection_summary_api: api).run

    assert stored_items.key?("a12345"), "purchased item should be stored"
    refute stored_items.key?("b67890"), "wishlist item should not be stored"
  end

  def test_existing_item_not_duplicated
    @store.transaction do
      @store[:items] = { "a12345" => { state: :ready, purchased: 12345 } }
    end

    api = fake_api(api_response(tralbum_lookup: {
      "a12345" => { "purchased" => "2024-01-15 12:00:00 UTC" },
      "b67890" => { "purchased" => "2024-02-20 08:00:00 UTC" }
    }))

    SyncCollection.new(store: @store, collection_summary_api: api).run

    assert_equal :ready, stored_items["a12345"][:state], "existing item state should not change"
    assert_equal :seen, stored_items["b67890"][:state], "new item should be added"
  end

  def test_fan_id_persisted_to_store
    api = fake_api(api_response(tralbum_lookup: {}, fan_id: "1313"))
    SyncCollection.new(store: @store, collection_summary_api: api).run
    assert_equal "1313", stored_fan_id
  end
end
