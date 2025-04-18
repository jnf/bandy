module API
  class CollectionItems < BaseAPI
    api_endpoint '/api/fancollection/1/collection_items'
    attr_reader :older_than_token, :fan_id
    attr_accessor :count

    def initialize(count: 50, starting_token: nil, fan_id: nil, debug: false)
      # tomorrow, tomorrow... need a token, for tomorrow
      @older_than_token = starting_token || "#{(Time.now.to_i + 86_400)}:0:a::"
      @fan_id = fan_id || fetch_fan_id
      @count = count
      super(debug: debug)
    end

    def fetch
      resp = post({ fan_id:, older_than_token:, count:, }.to_json)
      @older_than_token = resp["more_available"] && resp["items"].last["token"]
      binding.pry if resp["error"]
      [true, resp]
    rescue StandardError => e
      [false, e]
    end

    private

    def fetch_fan_id
      happy, deets = CollectionSummary.new.fetch
      raise deets unless happy
      deets["fan_id"]
    end
  end

  class HiddenItems < CollectionItems
    api_endpoint '/api/fancollection/1/hidden_items'
  end
end
