module WaybackArchiver
  class Request

    def self.get_response(url)
      uri = URI.parse(url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if url.include?('https://')

      request  = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      response
    end

  end
end
