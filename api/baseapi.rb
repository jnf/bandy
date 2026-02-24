module API
  class BaseAPI
    include HTTParty
    base_uri 'https://bandcamp.com'
    attr_reader :log, :http_client
    @@suffix_paths = Hash.new('')

    def initialize(debug: false, http_client: nil)
      @log = debug ? ::Logger.new($stdout) : ::Logger.new("./logs/#{self.class.name}.log", 'monthly')
      @http_client = http_client || self.class
      super()
    end

    def fetch
      raise NotImplementedError
    end

    def default_opts
      { headers: { "Cookie" => "identity=#{ENV['IDENT']}", } }
    end

    private

    def self.api_endpoint(suffix_path)
      @@suffix_paths[self.name] = suffix_path
    end

    def get
      log.info("BaseAPI: Get #{@@suffix_paths[self.class.name]}")
      http_client.get(@@suffix_paths[self.class.name], default_opts)
    end

    def post(body)
      log.info("BaseAPI: Post #{@@suffix_paths[self.class.name]}")
      log.info("BaseAPI: Post body: #{body}")
      http_client.post(@@suffix_paths[self.class.name], default_opts.merge({body:}))
    end
  end
end

# load all the child api classes
Dir[File.join(__dir__, '*.rb')].each { |file| require file }
