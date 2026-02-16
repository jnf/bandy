class DownloadItems
  attr_reader :debug, :store, :log, :format, :download_path, :freshness_threshold, :max_requeue_attempts

  def initialize(debug: DEBUG)
    @debug = debug
    @store = PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/download_items.log', 'monthly')
    @format = ENV.fetch('FORMAT', 'mp3-320')
    @download_path = ENV.fetch('DOWNLOAD_PATH', './downloads')
    @freshness_threshold = ENV.fetch('CDN_FRESHNESS_THRESHOLD', '300').to_i
    @max_requeue_attempts = ENV.fetch('MAX_REQUEUE_ATTEMPTS', '3').to_i
  end

  def run
    log.info("Starting Download Items")

    queued_items = store.transaction do
      store.fetch(:items, {}).select { |k, i| i[:state] == :queued }
    end

    log.info("Found #{queued_items.count} queued items")

    queued_items.each do |item_key, item|
      store.transaction do
        age = Time.now.to_i - item[:queued_at]

        if age > freshness_threshold
          # CDN URL might be stale, increment requeue count
          requeue_count = item.fetch(:requeue_count, 0) + 1

          if requeue_count > max_requeue_attempts
            # Too many attempts, mark as failed
            log.error("Item #{item_key} failed after #{requeue_count} requeue attempts")
            store[:items][item_key].merge!({
              state: :failed,
              error_message: "CDN URL expired #{requeue_count} times, giving up",
              failed_at: Time.now.to_i
            })
            next
          end

          # Re-queue with incremented counter
          log.warn("CDN URL for #{item_key} is #{age}s old, re-queuing (attempt #{requeue_count}/#{max_requeue_attempts})")
          store[:items][item_key].merge!({
            state: :ready,
            requeue_count: requeue_count
          })
          next
        end

        # Download from CDN URL
        begin
          log.info("Downloading #{item_key} from CDN (age: #{age}s)")
          local_path = download_file(item_key, item[:cdn_url], item[:digital_item])

          store[:items][item_key].merge!({
            state: :downloaded,
            local_path: local_path,
            downloaded_at: Time.now.to_i,
            requeue_count: 0  # Reset on success
          })

          log.info("Downloaded #{item_key}")
        rescue StandardError => e
          log.error("Download failed for #{item_key}: #{e.message}")
          # Leave in :queued state to retry
        end
      end
    end

    log.info("Download Items complete")
  rescue StandardError => e
    log.fatal("Download Items failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end

  private

  def download_file(item_key, cdn_url, digital_item)
    temp = Tempfile.new(binmode: true)
    log.info("temp name is #{File.basename(temp)}")

    begin
      dl = HTTParty.get(cdn_url, stream_body: true) do |fragment|
        raise StandardError.new "fragment fail: #{fragment.code}" unless [2, 3].include? fragment.code / 100
        temp.write(fragment)
      end

      dl_name = dl.headers["content-disposition"].match(/filename=(\"?)(.+)\1/)[2] # lol
      local_path = "#{download_path}/(#{item_key}) #{dl_name}"
      FileUtils.mv(temp.path, local_path)
      log.info("Saved #{item_key} to #{local_path}")
      local_path
    ensure
      temp.close
      temp.unlink
    end
  end
end
