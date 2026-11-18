require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'pstore'
require 'rbconfig'

require_relative '../scripts/outcome'

class TestOutcome < Minitest::Test
  OUTCOME_PATH = File.expand_path('../scripts/outcome.rb', __dir__)
  BANDY_PATH = File.expand_path('../bandy.rb', __dir__)
  TS = /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d/

  def setup
    @tmpdir = Dir.mktmpdir
    @children = []
    reset_state
  end

  def teardown
    @children.each do |pid|
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    reset_state
    FileUtils.rm_rf(@tmpdir)
  end

  # The module keeps its state in ivars (it lives for one process); the unit tests
  # share this process, so put them back between tests.
  def reset_state
    %i[@stage @success @counts].each { |iv| Outcome.remove_instance_variable(iv) if Outcome.instance_variable_defined?(iv) }
  end

  # --- Line format ---

  def test_ok_line_with_counts
    Outcome.succeed({ unpacked: 3, failed: 1, retrying: 2 })
    assert_match(/\A#{TS} ok unpacked=3 failed=1 retrying=2\z/, Outcome.line)
  end

  def test_ok_line_without_counts_when_they_could_not_be_computed
    Outcome.succeed(nil)
    assert_match(/\A#{TS} ok\z/, Outcome.line)
  end

  def test_failed_line_names_the_last_recorded_stage
    Outcome.stage = 'sync_collection'
    Outcome.stage = 'enrich_items'
    assert_match(/\A#{TS} failed enrich_items\z/, Outcome.line)
  end

  def test_failed_line_with_no_stage_is_failed_load
    assert_match(/\A#{TS} failed load\z/, Outcome.line)
  end

  def test_failed_line_carries_no_counts
    Outcome.stage = 'unpack_items'
    Outcome.instance_variable_set(:@counts, { unpacked: 2, failed: 0, retrying: 1 })
    assert_match(/\A#{TS} failed unpack_items\z/, Outcome.line)
  end

  def test_timestamp_is_local_iso8601_with_offset
    t = Time.new(2026, 11, 18, 3, 19, 44, '-08:00')
    assert_equal '2026-11-18T03:19:44-08:00 failed load', Outcome.line(t)
  end

  # --- Store diff ---

  def test_counts_new_unpacked_and_failed
    before = { 'a' => :downloaded, 'b' => :downloaded, 'c' => :ready }
    after  = { 'a' => :unpacked, 'b' => :failed, 'c' => :ready }
    assert_equal({ unpacked: 1, failed: 1, retrying: 0 }, Outcome.counts(before, after))
  end

  def test_counts_ignores_items_already_failed_or_unpacked_before
    before = { 'old_bad' => :failed, 'old_good' => :unpacked }
    after  = { 'old_bad' => :failed, 'old_good' => :unpacked }
    assert_equal({ unpacked: 0, failed: 0, retrying: 0 }, Outcome.counts(before, after))
  end

  def test_counts_includes_items_that_first_appear_in_a_final_state
    assert_equal({ unpacked: 1, failed: 1, retrying: 0 }, Outcome.counts({}, { 'n1' => :unpacked, 'n2' => :failed }))
  end

  # DownloadItems attempts every :queued item and UnpackItems every :downloaded one,
  # so any still in those states at the end failed this run and will be tried again.
  def test_counts_retrying_is_every_item_left_queued_or_downloaded
    before = { 'a' => :queued, 'b' => :queued, 'c' => :downloaded, 'd' => :ready }
    after  = { 'a' => :queued, 'b' => :queued, 'c' => :downloaded, 'd' => :ready }
    assert_equal({ unpacked: 0, failed: 0, retrying: 3 }, Outcome.counts(before, after))
  end

  def test_counts_retrying_ignores_where_the_item_started
    before = { 'a' => :ready, 'b' => :queued }
    after  = { 'a' => :queued, 'b' => :downloaded }
    assert_equal({ unpacked: 0, failed: 0, retrying: 2 }, Outcome.counts(before, after))
  end

  def test_counts_an_item_that_goes_all_the_way_through_counts_only_as_unpacked
    before = { 'a' => :queued }
    after  = { 'a' => :unpacked }
    assert_equal({ unpacked: 1, failed: 0, retrying: 0 }, Outcome.counts(before, after))
  end

  def test_counts_an_already_failed_item_counts_nowhere
    assert_equal({ unpacked: 0, failed: 0, retrying: 0 }, Outcome.counts({ 'a' => :failed }, { 'a' => :failed }))
  end

  def test_counts_nil_when_either_snapshot_is_missing
    assert_nil Outcome.counts(nil, { 'a' => :unpacked })
    assert_nil Outcome.counts({ 'a' => :seen }, nil)
  end

  def test_snapshot_reads_states_from_a_pstore
    store = PStore.new(File.join(@tmpdir, 'items.pstore'))
    store.transaction { store[:items] = { 'a' => { state: :ready, x: 1 }, 'b' => { state: :failed } } }
    assert_equal({ 'a' => :ready, 'b' => :failed }, Outcome.snapshot(store))
  end

  def test_snapshot_of_a_store_that_does_not_exist_yet_is_empty
    store = PStore.new(File.join(@tmpdir, 'missing.pstore'))
    assert_equal({}, Outcome.snapshot(store))
    refute File.exist?(File.join(@tmpdir, 'missing.pstore')), 'a read-only snapshot must not create the store'
  end

  def test_snapshot_is_nil_when_the_store_raises
    broken = Object.new
    broken.define_singleton_method(:transaction) { |*| raise IOError, 'unreadable' }
    assert_nil Outcome.snapshot(broken)
  end

  # --- Whole processes, one per case, each in its own tmp cwd ---

  # A driver that stands in for bandy.rb: loads outcome.rb first, installs the
  # handler, then runs fake stages. The mode picks how the run ends.
  DRIVER = <<~'RUBY'
    require ARGV[0]
    Outcome.install
    mode, ready = ARGV[1], ARGV[2]

    class FakeStage
      def initialize(name, &body)
        @name = name
        @body = body
      end

      def run
        Outcome.stage = @name
        @body&.call
      end
    end

    case mode
    when 'ok'
      FakeStage.new('sync_collection').run
      FakeStage.new('unpack_items').run
      Outcome.succeed({ unpacked: 2, failed: 1, retrying: 4 })
    when 'ok_no_counts'
      FakeStage.new('unpack_items').run
      Outcome.succeed(nil)
    when 'raise'
      FakeStage.new('sync_collection').run
      FakeStage.new('download_items') { raise 'boom from a stage' }.run
      Outcome.succeed({ unpacked: 9, failed: 9 })
    when 'term'
      FakeStage.new('enrich_items').run
      FakeStage.new('unpack_items') { File.write(ready, 'go'); sleep 30 }.run
      Outcome.succeed({ unpacked: 9, failed: 9 })
    when 'load'
      raise LoadError, 'cannot load such file -- httparty'
    when 'exit_nonzero'
      FakeStage.new('queue_items') { exit 3 }.run
    end
  RUBY

  Result = Struct.new(:out, :err, :status)

  def log_lines
    path = File.join(@tmpdir, 'logs', 'bandy.log')
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def driver_path
    path = File.join(@tmpdir, 'driver.rb')
    File.write(path, DRIVER) unless File.exist?(path)
    path
  end

  def spawn_driver(mode, ready: nil)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = Process.spawn(RbConfig.ruby, driver_path, OUTCOME_PATH, mode, ready.to_s,
                        chdir: @tmpdir, out: out_w, err: err_w)
    @children << pid
    out_w.close
    err_w.close
    [pid, out_r, err_r]
  end

  def finish(pid, out_r, err_r)
    out = out_r.read
    err = err_r.read
    Process.wait(pid)
    @children.delete(pid)
    Result.new(out, err, $?)
  end

  def run_driver(mode)
    finish(*spawn_driver(mode))
  end

  def wait_for(path, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until File.exist?(path)
      flunk "timed out waiting for #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  def test_success_writes_one_ok_line_with_counts
    result = run_driver('ok')
    assert result.status.success?, result.err
    assert_equal 1, log_lines.size
    assert_match(/\A#{TS} ok unpacked=2 failed=1 retrying=4\z/, log_lines.first)
  end

  def test_success_without_counts_writes_a_bare_ok
    result = run_driver('ok_no_counts')
    assert result.status.success?, result.err
    assert_match(/\A#{TS} ok\z/, log_lines.first)
  end

  def test_a_raising_stage_writes_failed_with_that_stage_and_still_exits_nonzero
    result = run_driver('raise')
    refute result.status.success?
    assert_equal 1, result.status.exitstatus
    assert_includes result.err, 'boom from a stage'
    assert_equal 1, log_lines.size
    assert_match(/\A#{TS} failed download_items\z/, log_lines.last)
  end

  def test_sigterm_mid_stage_writes_failed_with_that_stage
    ready = File.join(@tmpdir, 'ready')
    pid, out_r, err_r = spawn_driver('term', ready: ready)
    wait_for(ready)
    Process.kill('TERM', pid)
    result = finish(pid, out_r, err_r)
    assert result.status.signaled? || !result.status.success?, 'a TERMed run must not look like a success'
    assert_equal 1, log_lines.size
    assert_match(/\A#{TS} failed unpack_items\z/, log_lines.last)
  end

  def test_failure_before_any_stage_writes_failed_load
    result = run_driver('load')
    refute result.status.success?
    assert_includes result.err, 'httparty'
    assert_equal 1, log_lines.size
    assert_match(/\A#{TS} failed load\z/, log_lines.last)
  end

  def test_exit_with_a_status_inside_a_stage_is_a_failure_and_keeps_the_status
    result = run_driver('exit_nonzero')
    assert_equal 3, result.status.exitstatus
    assert_match(/\A#{TS} failed queue_items\z/, log_lines.last)
  end

  def test_two_runs_append_two_lines
    run_driver('ok')
    run_driver('raise')
    assert_equal 2, log_lines.size
    assert_match(/ ok unpacked=2 failed=1 retrying=4\z/, log_lines[0])
    assert_match(/ failed download_items\z/, log_lines[1])
  end

  def test_creates_logs_dir_when_missing
    refute Dir.exist?(File.join(@tmpdir, 'logs'))
    run_driver('ok')
    assert Dir.exist?(File.join(@tmpdir, 'logs'))
  end

  def test_a_failed_write_changes_neither_exit_status_nor_the_original_error
    File.write(File.join(@tmpdir, 'logs'), 'a file where the directory should be')
    ok = run_driver('ok')
    assert ok.status.success?, ok.err
    bad = run_driver('raise')
    assert_equal 1, bad.status.exitstatus
    assert_includes bad.err, 'boom from a stage'
  end

  # --- bandy.rb's wiring ---
  # bandy.rb can't run here (it would call Bandcamp), so pin what its source has to
  # keep true instead.

  def bandy_code
    File.readlines(BANDY_PATH, chomp: true, encoding: 'utf-8').reject { |l| l.strip.empty? || l.start_with?('#') }
  end

  def test_bandy_installs_the_handler_before_any_other_require
    assert_match(%r{\Arequire_relative ['"]scripts/outcome['"]\z}, bandy_code[0])
    assert_equal 'Outcome.install', bandy_code[1]
  end

  def test_bandy_records_each_stage_by_its_class_name_right_before_running_it
    code = bandy_code.map(&:strip).reject { |l| l.start_with?('#') }
    snake = ->(name) { name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase }
    recorded = []
    code.each_with_index do |line, i|
      next unless line.include?('.run')
      stage = code[i - 1][/\AOutcome\.stage = '(\w+)'\z/, 1] if i.positive?
      assert stage, "#{line.inspect} must be immediately preceded by an Outcome.stage line"
      klass = line[/\A(\w+)\.new/, 1]
      assert_equal stage, snake.call(klass), "#{line.inspect} is recorded as #{stage}" if klass
      recorded << stage
    end
    assert_equal %w[sync_collection enrich_items queue_items download_items unpack_items], recorded
  end

  def test_bandy_marks_success_only_after_the_last_stage
    code = bandy_code
    assert_match(/\AOutcome\.succeed\(/, code.last)
    assert_equal 1, code.count { |l| l.start_with?('Outcome.succeed') }
  end

  # The guard itself: a second install in the same process must not add a second handler.
  def test_installing_twice_in_one_process_writes_one_line
    File.write(File.join(@tmpdir, 'twice.rb'), <<~RUBY)
      require #{OUTCOME_PATH.inspect}
      Outcome.install
      Outcome.install
      Outcome.succeed(nil)
    RUBY
    pid = Process.spawn(RbConfig.ruby, File.join(@tmpdir, 'twice.rb'), chdir: @tmpdir)
    Process.wait(pid)
    assert_equal 1, log_lines.size
  end

  # bandy.rb loads outcome.rb by require_relative, then globs scripts/*.rb, which
  # reaches it again. Lay out a copy the way bandy is laid out and do both.
  def test_the_scripts_glob_reaching_outcome_again_registers_no_second_handler
    FileUtils.mkdir_p(File.join(@tmpdir, 'scripts'))
    FileUtils.cp(OUTCOME_PATH, File.join(@tmpdir, 'scripts', 'outcome.rb'))
    File.write(File.join(@tmpdir, 'probe.rb'), <<~RUBY)
      require_relative "scripts/outcome"
      Outcome.install
      Dir[File.join(__dir__, "scripts", "*.rb")].each { |file| require file }
      print $LOADED_FEATURES.count { |f| f.end_with?("scripts/outcome.rb") }
    RUBY
    pid = Process.spawn(RbConfig.ruby, File.join(@tmpdir, "probe.rb"), chdir: @tmpdir, out: File.join(@tmpdir, "loaded.txt"))
    Process.wait(pid)
    assert_equal "1", File.read(File.join(@tmpdir, "loaded.txt"))
    assert_equal 1, log_lines.size
  end
end
