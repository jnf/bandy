class QueueItems
  # An ExpirationError first resets the item to :seen, so enrichment fetches a fresh
  # redownload_url. If it expires again on that fresh URL, Bandcamp itself is refusing
  # the download (seen 2026-11-10: "Download expired" even after an email reauth), and
  # only a human can sort it out. Provisional; revisit if an item fails here and later works.
  MAX_EXPIRATIONS = 2

  attr_reader :debug, :store, :log, :format, :queue_limit, :resolver

  def initialize(debug: DEBUG, store: nil, resolver: nil)
    @debug = debug
    @store = store || PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/queue_items.log', 'monthly')
    @format = ENV.fetch('FORMAT', 'mp3-320')
    @queue_limit = ENV.fetch('QUEUE_LIMIT', '25').to_i
    @resolver = resolver || QueueResolver.new(format: format, debug: debug)
  end

  def run
    log.info("Starting Queue Items")

    ready_items = store.transaction do
      store.fetch(:items, {}).select { |k, i| i[:state] == :ready }.first(queue_limit)
    end

    log.info("Found #{ready_items.count} ready items (limit: #{queue_limit})")

    queued = 0
    ready_items.each do |item_key, item|
      store.transaction do
        log.info("Queuing #{item_key}")

        begin
          result = resolver.resolve(item[:redownload_url])

          # Store CDN URL with timestamp
          store[:items][item_key].merge!({
            cdn_url: result[:cdn_url],
            queued_at: Time.now.to_i,
            digital_item: result[:digital_item],
            state: :queued,
            expiration_count: 0
          })

          queued += 1
          log.info("Queued #{item_key} with CDN URL")
        rescue StandardError => e
          case e.message
          when /ExpirationError/
            expirations = item.fetch(:expiration_count, 0) + 1
            if expirations >= MAX_EXPIRATIONS
              log.error("#{item_key} download expired on Bandcamp even with a fresh URL, marking as :failed")
              store[:items][item_key].merge!({
                state: :failed,
                expiration_count: expirations,
                error_message: "Download expired on Bandcamp even with a fresh URL (needs a human)",
                failed_at: Time.now.to_i
              })
            else
              log.warn("#{item_key} redownload_url expired, resetting to :seen for re-enrichment")
              store[:items][item_key].merge!({ state: :seen, expiration_count: expirations })
            end
          when /NoSuchBandError/
            log.error("#{item_key} band/item no longer exists on Bandcamp, marking as :failed")
            store[:items][item_key].merge!({
              state: :failed,
              error_message: "Band/item removed from Bandcamp (NoSuchBandError)",
              failed_at: Time.now.to_i
            })
          else
            raise  # Re-raise unexpected errors
          end
        end
      end
    end

    log.info("Queue Items complete: #{queued} of #{ready_items.count} items queued")
  rescue StandardError => e
    log.fatal("Queue Items failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    raise
  end
end

class QueueResolver
  attr_reader :format, :pd

  def initialize(format:, debug:)
    @format = format
    @pd = API::PageData.new(debug: debug)
  end

  def resolve(redownload_url)
    pd.path = redownload_url
    happy, deets = pd.fetch
    raise deets unless happy

    digital_item = deets["digital_items"][0]
    cdn_resp = to_cdn(digital_item["downloads"][format]["url"])

    { digital_item: digital_item, cdn_url: cdn_resp["download_url"] }
  end

  private

  def to_cdn(url)
    munged = url.gsub(/\/download/, '/statdownload') + '&.vrs=1'
    res = HTTParty.get(munged, headers: { 'accept' => 'application/json', "Cookie" => "identity=#{ENV.fetch('IDENT')}" })
    raise StandardError.new res["errortype"] if res["result"] == "err"
    res
  end
end
