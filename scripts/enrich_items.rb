class EnrichItems
  attr_reader :store, :log, :fan_id, :debug, :known_preorders

  def initialize(debug: DEBUG, store: nil, hidden_items_api: nil, collection_items_api: nil)
    @debug = debug
    @store = store || PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/enrich_items.log', 'monthly')
    @hidden_items_api = hidden_items_api
    @collection_items_api = collection_items_api
  end

  def run
    @fan_id = store.transaction { store.fetch(:fan_id, nil) }
    @known_preorders = store.transaction { store.fetch(:items, {}).select { |k, i| i[:state] == :preorder } }.keys
    enrich_hidden_items
    enrich_collection_items
  rescue StandardError => e
    log.fatal("Item Enrichment failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end

  def enrich_hidden_items
    hi = @hidden_items_api || API::HiddenItems.new(fan_id: fan_id, debug: debug)
    fetch_items(hi)
  end

  def enrich_collection_items
    ci = @collection_items_api || API::CollectionItems.new(fan_id: fan_id, debug: debug)
    fetch_items(ci)
  end

  private

  def fetch_items(fetcher)
    items = store.transaction { store.fetch(:items, {} ) }
    while items.any? { |ik, i| i[:state] == :seen } || known_preorders.any?
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
          next unless record[:state] == :seen  || record[:state] == :preorder
          next if item["is_preorder"] && known_preorders.reject! { |kp| kp == tralbum_key }
          record.merge!({
            token: item["token"],
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
