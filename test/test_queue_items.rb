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

  # First strike: the redownload_url may just be stale, so re-enrich for a fresh one.
  def test_first_expiration_counts_one_strike
    seed_store({ "a123" => item })
    queue(resolver: failing_resolver(StandardError.new("ExpirationError")))
    assert_equal 1, stored_item("a123")[:expiration_count]
  end

  # Second strike: it expired again on a fresh URL. Bandcamp is refusing the file;
  # a human has to sort it out, so get it out of the queue.
  def test_second_expiration_marks_failed
    seed_store({ "a123" => item(expiration_count: 1) })
    queue(resolver: failing_resolver(StandardError.new("ExpirationError")))

    result = stored_item("a123")
    assert_equal :failed, result[:state]
    assert_match(/expired/i, result[:error_message])
    assert_kind_of Integer, result[:failed_at]
  end

  def test_successful_queue_clears_expiration_count
    seed_store({ "a123" => item(expiration_count: 1) })
    queue
    assert_equal :queued, stored_item("a123")[:state]
    assert_equal 0, stored_item("a123")[:expiration_count]
  end

  def test_completion_log_counts_only_items_actually_queued
    seed_store({ "a1" => item, "a2" => item(expiration_count: 1) })
    calls = 0
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do |*|
      calls += 1
      raise StandardError, "ExpirationError" if calls == 2
      { digital_item: {}, cdn_url: "x" }
    end
    out, _ = capture_io { QueueItems.new(debug: true, store: @store, resolver: resolver).run }
    assert_match(/Queue Items complete: 1 of 2 items queued/, out)
  end

  def test_no_such_band_error_marks_failed
    seed_store({ "a123" => item })
    queue(resolver: failing_resolver(StandardError.new("NoSuchBandError")))

    result = stored_item("a123")
    assert_equal :failed, result[:state]
    assert_kind_of String, result[:error_message]
    assert_kind_of Integer, result[:failed_at]
  end

  # --- Fatal path: run logs fatal, then re-raises the original error (no exit) ---

  Boom = Class.new(StandardError)

  def exploding_store
    store = Object.new
    store.define_singleton_method(:transaction) { |*| raise Boom, "kaboom" }
    store
  end

  # Runs the block with stdout captured (debug: true logs there). If the code under
  # test calls exit, fail the test instead of letting SystemExit end the suite:
  # assert_raises re-raises SystemExit rather than flunking on it.
  def capture_reraise
    err = nil
    out, _ = capture_io do
      err = assert_raises(Boom) do
        begin
          yield
        rescue SystemExit
          flunk "run called exit instead of re-raising the original error"
        end
      end
    end
    [err, out]
  end

  def test_unexpected_error_in_run_is_logged_fatal_and_reraised
    err, out = capture_reraise do
      QueueItems.new(debug: true, store: exploding_store,
                     resolver: fake_resolver({ digital_item: {}, cdn_url: "x" })).run
    end
    assert_instance_of Boom, err
    assert_equal "kaboom", err.message
    assert_match(/FATAL -- : Queue Items failed with error: kaboom/, out)
    assert_match(/FATAL -- : .*queue_items\.rb:\d+/, out, "backtrace should be logged at fatal")
  end
end
