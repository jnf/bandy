# The run's outcome: one line appended to logs/bandy.log however the process ends.
#
# Core Ruby only, on purpose. This file loads before the vendored gem setup, so it
# still works when loading gems is what failed -- and Logger is a bundled gem in
# Ruby 4, reached through that same setup, so it can't be used here either.
#
# One at_exit handler is enough: Ruby runs it on a normal exit, on an uncaught
# exception, and on SIGTERM (the default handler raises SignalException). Only
# SIGKILL and a pulled plug skip it; a reader treats a stale last line as the sign.
module Outcome
  LOG_PATH = File.join('logs', 'bandy.log')

  # An item stuck in download or unpack is retried the next run, and shows up in one
  # of two ways. It stays in the state the stage works from (RETRYING), or the stage
  # sends it back to :ready to be queued again (a stale CDN URL, a corrupt zip);
  # SENT_BACK_FROM are the states it can be sent back from.
  RETRYING = %i[queued downloaded].freeze
  SENT_BACK_FROM = RETRYING

  @installed ||= false

  class << self
    # Register the handler once; a second call (or a second load of this file) is a no-op.
    def install
      return if @installed
      @installed = true
      @pid = Process.pid
      at_exit { write if Process.pid == @pid }
    end

    # Name the stage about to run: its class name in snake_case (SyncCollection
    # is 'sync_collection'), whatever its own log file is called.
    def stage=(name)
      @stage = name.to_s
    end

    # Mark the run good. counts is { unpacked: N, failed: M, retrying: K }, or nil
    # when they couldn't be worked out (the run still succeeded).
    def succeed(counts = nil)
      @success = true
      @counts = counts
    end

    # The line for the current state; a failed run never carries counts.
    def line(now = Time.now)
      ts = now.strftime('%Y-%m-%dT%H:%M:%S%:z')
      if @success
        return "#{ts} ok" unless @counts
        "#{ts} ok unpacked=#{@counts[:unpacked]} failed=#{@counts[:failed]} retrying=#{@counts[:retrying]}"
      else
        "#{ts} failed #{@stage || 'load'}"
      end
    end

    # Append the line. Runs inside at_exit, so it must never raise: a write error
    # would replace the original error and the process's exit status.
    def write
      text = line + "\n"
      Dir.mkdir('logs') unless Dir.exist?('logs')
      File.open(LOG_PATH, 'a') { |f| f.write(text) }
    rescue Exception # rubocop:disable Lint/RescueException
      nil
    end

    # item key => :state, read the way the stages read the store (a read-only
    # transaction). Takes any object with PStore's interface. nil when the store
    # can't be read, so the caller can still run.
    def snapshot(store)
      store.transaction(true) do
        store.fetch(:items, {}).each_with_object({}) { |(key, item), states| states[key] = item[:state] }
      end
    rescue StandardError
      nil
    end

    # What this run did: items that reached :unpacked or :failed since before (an
    # item already in that state beforehand isn't this run's work), and how many
    # are still to retry. DownloadItems attempts every :queued item that's still fresh,
    # and UnpackItems every :downloaded one with a zip path, so any left in those
    # states at the end failed this run and will be tried again, wherever they
    # started. The other way an item
    # gets retried: DownloadItems moves a stale :queued item back to :ready without
    # an attempt, and UnpackItems resets a corrupt zip's :downloaded item to :ready.
    # Those end :ready, so they only show as :queued/:downloaded before and :ready
    # after. nil if either snapshot is missing.
    def counts(before, after)
      return nil unless before && after
      {
        unpacked: after.count { |key, state| state == :unpacked && before[key] != :unpacked },
        failed: after.count { |key, state| state == :failed && before[key] != :failed },
        retrying: after.count { |key, state| RETRYING.include?(state) || (state == :ready && SENT_BACK_FROM.include?(before[key])) }
      }
    end
  end
end
