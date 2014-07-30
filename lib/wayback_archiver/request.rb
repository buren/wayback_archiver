module WaybackArchiver
  class Request

    def self.get_response(url)
      Net::HTTP.get_response(URI.parse(url))
    end

  end
end
