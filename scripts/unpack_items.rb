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

        FileUtils.mkdir_p(extract_dir)
        begin
          # Each branch does only its own work; success handling is shared below
          if item[:digital_item]["download_type"] == 't' # tracks don't get unpacked, they get copied
            ext = item[:local_path].split('.').last
            dest_file = File.join(extract_dir,"#{title}.#{ext}")
            log.info("#{item_key} is a track; copying to #{dest_file}")
            FileUtils.cp(item[:local_path], dest_file)
          else # Extract zip file
            log.info("Unpacking #{item_key} from #{zip_path}")
            Zip::File.open(zip_path) do |zip_file|
              # Resolve every destination before writing anything, so a refused
              # archive leaves nothing behind.
              targets = zip_file.filter_map do |entry|
                relative = safe_relative_path(entry.name.force_encoding('utf-8'))
                next if relative.empty?
                [entry, relative, contained_path(extract_dir, relative)]
              end

              targets.each do |entry, relative, dest_path|
                FileUtils.mkdir_p(File.dirname(dest_path))
                next if File.exist?(dest_path)
                entry.extract(relative, destination_directory: extract_dir)
              end
            end
          end

          # Shared success block: tracks and albums both end here
          log.info("Unpacked #{item_key} to #{extract_dir}")

          # Optionally delete the source (archive or track) after success
          if delete_after_unpack
            File.delete(zip_path) if File.exist?(zip_path)
            log.info("Deleted source #{zip_path}")
          end

          store[:items][item_key].merge!({
            state: :unpacked,
            unpacked_path: extract_dir,
            unpacked_at: Time.now.to_i
          })
        rescue UnsafeEntryError => e
          # Not retryable: the same archive resolves the same way every run
          log.error("Refused #{item_key}, archive kept at #{zip_path}: #{e.message}")
          store[:items][item_key][:state] = :failed
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
    raise
  end

  private

  # Entry names come from the archive. Most odd ones are honest (a track titled "..",
  # a Windows backslash), so rewrite them into the album rather than reject them:
  # drop empty, "." and ".." segments, which also strips a leading slash.
  def safe_relative_path(name)
    name.split(%r{[/\\]}).reject { |seg| seg.empty? || seg == '.' || seg == '..' }.join('/')
  end

  # The guarantee under safe_relative_path: whatever the name, the destination
  # stays inside dir, or the whole archive is refused.
  def contained_path(dir, relative)
    root = File.expand_path(dir)
    path = File.expand_path(relative, root)
    unless path.start_with?(root + File::SEPARATOR)
      raise UnsafeEntryError, "#{relative.inspect} resolves outside #{root}"
    end
    path
  end

  class UnsafeEntryError < StandardError; end
end
