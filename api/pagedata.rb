module API
  # pagedata is a little bit different in that it's scraping a json blob from a html page
  # rather than communicating with an api endpoint. still, how bandy is going to use the data is
  # much the same as the other api classes, so let's try to make it look and feel like the others
  class PageData < BaseAPI
    attr_accessor :path

    def initialize(path: nil, debug: false)
      @path = path
      super(debug: debug)
    end

    def fetch
      html = Nokogiri::HTML5::Document.parse(get.body)
      pd = html.css('#pagedata').first
      [true, JSON.parse(pd.attributes["data-blob"].value)]
    rescue StandardError => e
      [false, e]
    end

    private
    def get
      log.info("API::PageData: Get #{path}")
      self.class.get(path, default_opts)
    end
  end
end
