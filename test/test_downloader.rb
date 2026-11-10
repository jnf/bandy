require 'minitest/autorun'
require 'tmpdir'
require 'tempfile'
require 'fileutils'
require 'logger'

DEBUG = false unless defined?(DEBUG)

require_relative '../scripts/download_items'

class TestDownloader < Minitest::Test
  # A streamed body fragment: a String that also answers #code, like HTTParty's.
  class Fragment < String
    def code = 200
  end

  Response = Struct.new(:headers)

  def setup
    @tmpdir = Dir.mktmpdir
    @download_path = File.join(@tmpdir, 'downloads')
    FileUtils.mkdir_p(@download_path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # Streams the given chunks, then answers with a content-disposition header.
  def fake_http(chunks, filename: "Artist - Album.zip")
    http = Object.new
    http.define_singleton_method(:get) do |*_, **_, &blk|
      chunks.each { |c| blk.call(Fragment.new(c)) }
      Response.new({ "content-disposition" => %(attachment; filename="#{filename}") })
    end
    http
  end

  def downloader(http)
    Downloader.new(download_path: @download_path, log: Logger.new(File::NULL), http: http)
  end

  # On the jukebox, the tempfile and DOWNLOAD_PATH are on different filesystems
  # (/tmp is tmpfs), so mv is a copy, not a rename. Simulate that here.
  def with_cross_device_mv
    original = FileUtils.method(:mv)
    FileUtils.define_singleton_method(:mv) do |src, dest, **_|
      FileUtils.cp(src, dest)
      FileUtils.rm(src)
    end
    yield
  ensure
    FileUtils.define_singleton_method(:mv, original)
  end

  # Big fragments bypass Ruby's write buffer; a small final one sits in it.
  # A zip's central directory lives at the very end, so losing that tail is fatal.
  def chunks
    ["A" * 20_000, "B" * 20_000, "END-OF-CENTRAL-DIRECTORY"]
  end

  def test_saved_file_is_complete_across_filesystems
    path = nil
    with_cross_device_mv { path = downloader(fake_http(chunks)).call("a123", "https://cdn.example/x", {}) }
    assert_equal chunks.join, File.binread(path)
  end

  def test_saved_file_is_complete_on_same_filesystem
    path = downloader(fake_http(chunks)).call("a123", "https://cdn.example/x", {})
    assert_equal chunks.join, File.binread(path)
  end

  def test_saves_under_download_path_with_item_key_and_server_filename
    path = downloader(fake_http(chunks)).call("a123", "https://cdn.example/x", {})
    assert_equal File.join(@download_path, "(a123) Artist - Album.zip"), path
  end

  # /tmp on the jukebox is RAM. A whole album staged there competes with mpd.
  def test_stages_the_download_on_the_download_path_filesystem_not_tmpdir
    staged = []
    original = Tempfile.method(:new)
    Tempfile.define_singleton_method(:new) do |*args, **kw|
      t = original.call(*args, **kw)
      staged << File.dirname(t.path)
      t
    end
    downloader(fake_http(chunks)).call("a123", "https://cdn.example/x", {})
    assert_equal [File.realpath(@download_path)], staged.map { |d| File.realpath(d) }
  ensure
    Tempfile.define_singleton_method(:new, original)
  end
end
