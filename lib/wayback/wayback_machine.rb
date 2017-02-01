require 'net/http'
require 'uri'

module WaybackArchiver
  class WaybackMachine
    WAYBACK_BASE_URL = 'https://web.archive.org/save/'.freeze

    def self.save(url)
      uri = URI.parse(WAYBACK_BASE_URL + url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = WaybackArchiver::USER_AGENT
      http.request(request)
    end
  end
end
