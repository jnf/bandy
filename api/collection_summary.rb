module API
  class CollectionSummary < BaseAPI
    api_endpoint '/api/fan/2/collection_summary'
    def fetch
      [true, get]
    rescue StandardError => e
      [false, e]
    end
  end
end
