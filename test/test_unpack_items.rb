require 'minitest/autorun'
require 'tmpdir'
require 'pstore'
require 'logger'
require 'fileutils'
require 'zip'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/unpack_items'

class TestUnpackItems < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @store = PStore.new(File.join(@tmpdir, "test.pstore"))
    ENV['UNPACK_PATH'] = File.join(@tmpdir, 'collection')
    ENV['DELETE_AFTER_UNPACK'] = 'false'
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  # Default item for tests that need one; override any field as needed.
  def item(overrides = {})
    {
      state: :downloaded,
      local_path: File.join(@tmpdir, "album.zip"),
      digital_item: {
        "artist" => "Test Artist",
        "title" => "Test Album",
        "download_type" => "a"
      }
    }.merge(overrides)
  end

  def seed_store(items)
    @store.transaction { @store[:items] = items }
  end

  def stored_state(key)
    @store.transaction { @store[:items][key][:state] }
  end

  def stored_item(key)
    @store.transaction { @store[:items][key] }
  end

  def make_zip(path)
    Zip::OutputStream.open(path) do |zip|
      zip.put_next_entry("track01.mp3")
      zip.write("this is a song about cats. and love. but mostly cats.")
    end
  end

  def expected_extract_dir
    File.join(ENV['UNPACK_PATH'], "Test Artist", "Test Album")
  end

  # --- Tests ---

  def test_nil_local_path_resets_to_ready
    seed_store("a123" => item(local_path: nil))
    UnpackItems.new(store: @store).run
    assert_equal :ready, stored_state("a123")
  end

  def test_already_extracted_marks_as_unpacked
    FileUtils.mkdir_p(expected_extract_dir)
    File.write(File.join(expected_extract_dir, "track01.mp3"), "data")

    seed_store("a123" => item)
    UnpackItems.new(store: @store).run

    result = stored_item("a123")
    assert_equal :unpacked, result[:state]
    assert_equal expected_extract_dir, result[:unpacked_path]
    assert_kind_of Integer, result[:unpacked_at]
  end

  def test_successful_unpack_marks_as_unpacked
    make_zip(item[:local_path])
    seed_store("a123" => item)
    UnpackItems.new(store: @store).run

    result = stored_item("a123")
    assert_equal :unpacked, result[:state]
    assert_equal expected_extract_dir, result[:unpacked_path]
    assert_kind_of Integer, result[:unpacked_at]
  end

  def test_successful_unpack_keeps_archive_by_default
    zip_path = item[:local_path]
    make_zip(zip_path)
    seed_store("a123" => item)
    UnpackItems.new(store: @store).run
    assert File.exist?(zip_path), "archive should not be deleted when DELETE_AFTER_UNPACK=false"
  end

  def test_delete_after_unpack_removes_archive
    ENV['DELETE_AFTER_UNPACK'] = 'true'
    zip_path = item[:local_path]
    make_zip(zip_path)
    seed_store("a123" => item)
    UnpackItems.new(store: @store).run
    refute File.exist?(zip_path), "archive should be deleted when DELETE_AFTER_UNPACK=true"
  end

  def test_corrupted_zip_resets_to_ready_and_deletes_file
    zip_path = item[:local_path]
    File.write(zip_path, "this is not a zip file")
    seed_store("a123" => item)
    UnpackItems.new(store: @store).run
    assert_equal :ready, stored_state("a123")
    refute File.exist?(zip_path), "corrupted zip should be deleted"
  end

  def test_other_unpack_error_leaves_as_downloaded
    seed_store("a123" => item(local_path: "/nonexistent/path.zip"))
    UnpackItems.new(store: @store).run
    assert_equal :downloaded, stored_state("a123")
  end

  # --- Single-track downloads (download_type "t") share the album success path ---

  def track_item(overrides = {})
    item({
      local_path: File.join(@tmpdir, "song.mp3"),
      digital_item: {
        "artist" => "Test Artist",
        "title" => "Test Song",
        "download_type" => "t"
      }
    }.merge(overrides))
  end

  def expected_track_file
    File.join(ENV['UNPACK_PATH'], "Test Artist", "Test Song", "Test Song.mp3")
  end

  def test_track_is_unpacked_after_one_run
    File.write(track_item[:local_path], "song data")
    seed_store("t123" => track_item)
    UnpackItems.new(store: @store).run

    result = stored_item("t123")
    assert_equal :unpacked, result[:state]
    assert_equal File.join(ENV['UNPACK_PATH'], "Test Artist", "Test Song"), result[:unpacked_path]
    assert_kind_of Integer, result[:unpacked_at]
    assert_equal "song data", File.read(expected_track_file)
  end

  def test_track_source_kept_by_default
    src = track_item[:local_path]
    File.write(src, "song data")
    seed_store("t123" => track_item)
    UnpackItems.new(store: @store).run
    assert File.exist?(src), "track source should be kept when DELETE_AFTER_UNPACK=false"
    assert File.exist?(expected_track_file)
  end

  def test_delete_after_unpack_removes_track_source
    ENV['DELETE_AFTER_UNPACK'] = 'true'
    src = track_item[:local_path]
    File.write(src, "song data")
    seed_store("t123" => track_item)
    UnpackItems.new(store: @store).run
    refute File.exist?(src), "track source should be deleted when DELETE_AFTER_UNPACK=true"
    assert_equal "song data", File.read(expected_track_file), "the copy must survive the source delete"
  end

  def test_failed_track_copy_leaves_as_downloaded
    ENV['DELETE_AFTER_UNPACK'] = 'true'
    seed_store("t123" => track_item(local_path: File.join(@tmpdir, "missing.mp3")))
    UnpackItems.new(store: @store).run
    result = stored_item("t123")
    assert_equal :downloaded, result[:state]
    refute result.key?(:unpacked_at)
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
      UnpackItems.new(debug: true, store: exploding_store).run
    end
    assert_instance_of Boom, err
    assert_equal "kaboom", err.message
    assert_match(/FATAL -- : Unpack Items failed with error: kaboom/, out)
    assert_match(/FATAL -- : .*unpack_items\.rb:\d+/, out, "backtrace should be logged at fatal")
  end
end
