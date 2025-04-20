class SyncCollection
  attr_reader :log, :store, :debug

  def initialize(debug: false)
    @debug = debug
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/collection_sync.log', 'monthly')
    @store = PStore.new('./store/collection_items.pstore')
  end

  def run
    log.info("Starting Collection Sync")
    cs = API::CollectionSummary.new(debug: debug)
    happy, deets = cs.fetch
    raise deets unless happy # will eventually need real error handling
    sync_items = deets["collection_summary"]["tralbum_lookup"]
    sync_items.select! { |k, v| v["purchased"] } # items w/o a purchased date are wishlist
    log.info("Found #{sync_items.count} items in remote collection for fan #{deets["fan_id"]}.")
    store.transaction do
      store[:fan_id] = deets["fan_id"] # we'll need this to enrich the found items later
      store_items = store.fetch(:items, {})
      new_keys = sync_items.keys - store_items.keys # these are the tralbums we've added since last run
      log.info("#{new_keys.count} new items for local collection.")
      new_keys.each do |key|
        log.info("Writing #{key} (purchased #{sync_items[key]["purchased"]}) to item store.")
        store_items[key] = {
          purchased: DateTime.parse(sync_items[key]["purchased"]).to_time.to_i,
          state: :seen, # gonna make a lil state machine maybe
        }
      end
      store[:items] = store_items # persist the new entries
    end
  rescue StandardError => e
    log.error("Collection Sync died with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end
end
