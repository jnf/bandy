require 'minitest/autorun'
require 'tmpdir'
require 'pstore'
require 'logger'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/download_items'

class TestDownloadItems < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = PStore.new(File.join(@tmpdir, "test.pstore"))
    ENV['CDN_FRESHNESS_THRESHOLD'] = '300'
    ENV['MAX_REQUEUE_ATTEMPTS'] = '3'
    ENV['DOWNLOAD_PATH'] = File.join(@tmpdir, 'downloads')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  def item(overrides = {})
    {
      state: :queued,
      queued_at: Time.now.to_i,
      cdn_url: "https://example.com/dl",
      digital_item: {}
    }.merge(overrides)
  end

  def seed_store(items)
    @store.transaction { @store[:items] = items }
  end

  def stored_item(key)
    @store.transaction { @store[:items][key] }
  end

  def fake_downloader(result)
    obj = Object.new
    obj.define_singleton_method(:call) { |*| result }
    obj
  end

  def failing_downloader(error)
    obj = Object.new
    obj.define_singleton_method(:call) { |*| raise error }
    obj
  end

  def download(downloader: fake_downloader("/tmp/fake.zip"))
    DownloadItems.new(store: @store, downloader: downloader).run
  end

  # --- Tests ---

  def test_no_queued_items_is_noop
    seed_store({ "a123" => { state: :ready }, "b456" => { state: :downloaded } })
    download
    assert_equal :ready, stored_item("a123")[:state]
    assert_equal :downloaded, stored_item("b456")[:state]
  end

  def test_stale_url_requeues_to_ready
    seed_store({ "a123" => item(queued_at: Time.now.to_i - 600) })
    download
    result = stored_item("a123")
    assert_equal :ready, result[:state]
    assert_equal 1, result[:requeue_count]
  end

  def test_stale_url_exceeding_max_requeue_fails
    seed_store({ "a123" => item(queued_at: Time.now.to_i - 600, requeue_count: 3) })
    download
    result = stored_item("a123")
    assert_equal :failed, result[:state]
    assert_kind_of String, result[:error_message]
    assert_kind_of Integer, result[:failed_at]
  end

  def test_fresh_url_successful_download
    seed_store({ "a123" => item })
    download(downloader: fake_downloader("/tmp/album.zip"))
    result = stored_item("a123")
    assert_equal :downloaded, result[:state]
    assert_equal "/tmp/album.zip", result[:local_path]
    assert_kind_of Integer, result[:downloaded_at]
    assert_equal 0, result[:requeue_count]
  end

  def test_fresh_url_download_error_stays_queued
    seed_store({ "a123" => item })
    download(downloader: failing_downloader(StandardError.new("network error")))
    assert_equal :queued, stored_item("a123")[:state]
  end

  def test_requeue_count_preserved_across_requeues
    seed_store({ "a123" => item(queued_at: Time.now.to_i - 600, requeue_count: 1) })
    download
    assert_equal 2, stored_item("a123")[:requeue_count]
  end

  def test_successful_download_resets_requeue_count
    seed_store({ "a123" => item(requeue_count: 2) })
    download(downloader: fake_downloader("/tmp/album.zip"))
    assert_equal 0, stored_item("a123")[:requeue_count]
  end
end
