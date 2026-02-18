require 'minitest/autorun'
require 'tmpdir'
require 'pstore'
require 'logger'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/queue_items'

class TestQueueItems < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = PStore.new(File.join(@tmpdir, "test.pstore"))
    ENV['QUEUE_LIMIT'] = '25'
    ENV['FORMAT'] = 'mp3-320'
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  def item(overrides = {})
    {
      state: :ready,
      redownload_url: "https://example.com/redownload"
    }.merge(overrides)
  end

  def seed_store(items)
    @store.transaction { @store[:items] = items }
  end

  def stored_item(key)
    @store.transaction { @store[:items][key] }
  end

  def fake_resolver(result)
    obj = Object.new
    obj.define_singleton_method(:resolve) { |*| result }
    obj
  end

  def failing_resolver(error)
    obj = Object.new
    obj.define_singleton_method(:resolve) { |*| raise error }
    obj
  end

  def queue(resolver: fake_resolver({ digital_item: { "name" => "test" }, cdn_url: "https://cdn.example.com/dl" }))
    QueueItems.new(store: @store, resolver: resolver).run
  end

  # --- Tests ---

  def test_no_ready_items_is_noop
    seed_store({ "a123" => { state: :seen }, "b456" => { state: :downloaded } })
    queue
    assert_equal :seen, stored_item("a123")[:state]
    assert_equal :downloaded, stored_item("b456")[:state]
  end

  def test_queue_limit_respected
    ENV['QUEUE_LIMIT'] = '2'
    seed_store({
      "a1" => item,
      "a2" => item,
      "a3" => item
    })
    queue
    items = @store.transaction { @store[:items] }
    queued_count = items.count { |_, i| i[:state] == :queued }
    ready_count = items.count { |_, i| i[:state] == :ready }
    assert_equal 2, queued_count
    assert_equal 1, ready_count
  end

  def test_successful_queue
    seed_store({ "a123" => item })
    digital_item = { "name" => "Test Album" }
    queue(resolver: fake_resolver({ digital_item: digital_item, cdn_url: "https://cdn.example.com/dl" }))

    result = stored_item("a123")
    assert_equal :queued, result[:state]
    assert_equal "https://cdn.example.com/dl", result[:cdn_url]
    assert_equal digital_item, result[:digital_item]
    assert_kind_of Integer, result[:queued_at]
  end

  def test_expiration_error_resets_to_seen
    seed_store({ "a123" => item })
    queue(resolver: failing_resolver(StandardError.new("ExpirationError")))
    assert_equal :seen, stored_item("a123")[:state]
  end

  def test_no_such_band_error_marks_failed
    seed_store({ "a123" => item })
    queue(resolver: failing_resolver(StandardError.new("NoSuchBandError")))

    result = stored_item("a123")
    assert_equal :failed, result[:state]
    assert_kind_of String, result[:error_message]
    assert_kind_of Integer, result[:failed_at]
  end
end
