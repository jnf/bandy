class EnrichItems
  attr_reader :store, :log, :fan_id, :debug

  def initialize(debug: false)
    @debug = debug
    @store = PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/enrich_items.log', 'monthly')
    @fan_id = store.transaction { store.fetch(:fan_id, nil) }
  end

  def run
    enrich_hidden_items
    enrich_collection_items
  rescue StandardError => e
    log.fatal("Item Enrichment failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end

  def enrich_hidden_items
    hi = API::HiddenItems.new(fan_id: fan_id, debug: debug)
    fetch_items(hi)
  end

  def enrich_collection_items
    ci = API::CollectionItems.new(fan_id: fan_id, debug: debug)
    fetch_items(ci)
  end

  private

  def fetch_items(fetcher)
    items = store.transaction { store.fetch(:items, {} ) }
    while items.any? { |ik, i| i[:state] == :seen }
      happy, deets = fetcher.fetch
      raise deets unless happy
      items = update_store(deets)
      break unless deets["more_available"]
    end
  end

  def update_store(deets)
    store.transaction do
      deets["items"].each do |item|
        tralbum_key = item["tralbum_type"] + item["tralbum_id"].to_s
        sale_key = item["sale_item_type"] + item["sale_item_id"].to_s
        record = store[:items][tralbum_key]
        if record
          next unless record[:state] == :seen
          record.merge!({
            token: item["token"],
            is_preorder: item["is_preorder"],
            redownload_url: deets["redownload_urls"][sale_key],
            state: item["is_preorder"] ? :preorder : :ready,
          })
          log.info("Enriched store item #{tralbum_key} (#{item['band_name']}, #{item['album_title']})")
        else
          log.warn("Unable to match API return item #{tralbum_key} with an existing store item. Skipping.")
        end
      end
      store.fetch(:items, {})
    end
  end
end
