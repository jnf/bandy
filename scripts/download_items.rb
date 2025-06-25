class DownloadItems
  attr_reader :debug, :store, :log, :format, :download_path

  def initialize(debug: DEBUG)
    @debug = debug
    @store = PStore.new('./store/collection_items.pstore')
    @log = debug ? Logger.new($stdout) : Logger.new('./logs/enrich_items.log', 'monthly')
    @format = ENV['FORMAT']
    @download_path = ENV['DOWNLOAD_PATH']
  end

  def run
    pd = API::PageData.new(debug: debug)
    ready_items = store.transaction do
      store.fetch(:items, {}).select { |ik, it| it[:state] == :ready }
    end
    ready_items.each do |ik, it|
      store.transaction do
        pd.path = it[:redownload_url]
        happy, deets = pd.fetch
        raise deets unless happy
        if local_path = download_file(ik, deets["digital_items"][0])
          store[:items][ik][:state] = :downloaded
          store[:items][ik][:local_path] = local_path
        end
      end
    end
  rescue StandardError => e
    log.fatal("Item Download failed with error: #{e}")
    e.backtrace.each { |m| log.fatal(m) }
    exit(1)
  end

  private
  def to_cdn(url)
    munged = url.gsub(/\/download/, '/statdownload') + '&.vrs=1'
    res = HTTParty.get(munged, headers: { 'accept' => 'application/json', "Cookie" => "identity=#{ENV['IDENT']}" })
    raise StandardError.new res["errortype"] if res["result"] == "err"
    res
  end

  def download_file(item_key, digital_item)
    url = digital_item["downloads"][format]["url"]
    cdn_resp = to_cdn(url)
    cdn_url = cdn_resp["download_url"]
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
