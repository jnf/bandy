require 'zip'  # rubyzip gem

class UnpackItems
  attr_reader :debug, :store, :log, :unpack_path, :delete_after_unpack

  def initialize(debug: DEBUG, store: nil)
    @debug = debug
    @store = store || PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/unpack_items.log', 'monthly')
    @unpack_path = ENV.fetch('UNPACK_PATH', './collection')
    @delete_after_unpack = ENV.fetch('DELETE_AFTER_UNPACK', 'false') == 'true'
  end

  def run
    log.info("Starting Unpack Items")

    downloaded_items = store.transaction do
      store.fetch(:items, {}).select { |k, i| i[:state] == :downloaded }
    end

    log.info("Found #{downloaded_items.count} downloaded items to unpack")

    downloaded_items.each do |item_key, item|
      store.transaction do
        # Skip items without local_path (legacy data)
        unless item[:local_path]
          log.warn("#{item_key} is :downloaded but missing local_path, resetting to :ready")
          store[:items][item_key][:state] = :ready
          next
        end

        zip_path = item[:local_path]
        artist = item[:digital_item]["artist"]
        title = item[:digital_item]["title"]
        extract_dir = File.join(unpack_path, artist, title)

        # Skip if already extracted
        if Dir.exist?(extract_dir) && !Dir.empty?(extract_dir)
          log.info("#{item_key} already unpacked, skipping extraction")
          store[:items][item_key].merge!({
            state: :unpacked,
            unpacked_path: extract_dir,
            unpacked_at: Time.now.to_i
          })
          next
        end

        # Extract zip file
        log.info("Unpacking #{item_key} from #{zip_path}")
        FileUtils.mkdir_p(extract_dir)

        begin
          Zip::File.open(zip_path) do |zip_file|
            zip_file.each do |entry|
              dest_path = File.join(extract_dir, entry.name.force_encoding('utf-8'))
              FileUtils.mkdir_p(File.dirname(dest_path))
              entry.extract(dest_path) unless File.exist?(dest_path)
            end
          end

          log.info("Unpacked #{item_key} to #{extract_dir}")

          # Optionally delete archive after successful unpacking
          if delete_after_unpack
            File.delete(zip_path) if File.exist?(zip_path)
            log.info("Deleted archive #{zip_path}")
          end

          store[:items][item_key].merge!({
            state: :unpacked,
            unpacked_path: extract_dir,
            unpacked_at: Time.now.to_i
          })
        rescue StandardError => e
          # Handle corrupted/incomplete zip files
          if e.message.include?("Zip end of central directory signature not found")
            log.warn("#{item_key} has corrupted zip file, deleting and resetting to :ready for re-download")
            File.delete(zip_path) if File.exist?(zip_path)
            store[:items][item_key][:state] = :ready
          else
            log.error("Unpack failed for #{item_key}: #{e.message}")
            # Leave in :downloaded state to retry next execution
          end
        end
      end
    end

    log.info("Unpack Items complete")
  rescue StandardError => e
    log.fatal("Unpack Items failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end
end
