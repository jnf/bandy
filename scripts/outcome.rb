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

  @installed ||= false

  class << self
    # Register the handler once; a second call (or a second load of this file) is a no-op.
    def install
      return if @installed
      @installed = true
      @pid = Process.pid
      at_exit { write if Process.pid == @pid }
    end

    # Name the stage about to run, in the snake_case of its stage log.
    def stage=(name)
      @stage = name.to_s
    end

    # Mark the run good. counts is { unpacked: N, failed: M }, or nil when they
    # couldn't be worked out (the run still succeeded).
    def succeed(counts = nil)
      @success = true
      @counts = counts
    end

    # The line for the current state; a failed run never carries counts.
    def line(now = Time.now)
      ts = now.strftime('%Y-%m-%dT%H:%M:%S%:z')
      if @success
        return "#{ts} ok" unless @counts
        "#{ts} ok unpacked=#{@counts[:unpacked]} failed=#{@counts[:failed]}"
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

    # What this run did: items that reached :unpacked or :failed since before.
    # An item already in that state beforehand isn't this run's work. nil if
    # either snapshot is missing.
    def counts(before, after)
      return nil unless before && after
      {
        unpacked: after.count { |key, state| state == :unpacked && before[key] != :unpacked },
        failed: after.count { |key, state| state == :failed && before[key] != :failed }
      }
    end
  end
end
