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
      band_name: "Test Artist",
      album_title: "Test Album"
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
end
