require 'url_resolver'

module WaybackArchiver
  # Make simple HTTP requests
  class Request
    # Get reponse.
    # @return [Net::HTTP*] the http response.
    # @param [String] url URL to retrieve.
    # @param [Boolean] resolve whether to resolve the URL.
    # @example Resolve example.com and request
    #    Request.response('example.com', true)
    # @example Request http://example.com
    #    Request.response('http://example.com', false)
    def self.response(url, resolve = true)
      resolved_url = resolve ? resolve_url(url) : url
      uri          = URI.parse(resolved_url)
      http         = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if resolved_url.start_with?('https://')

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = WaybackArchiver::USER_AGENT
      http.request(request)
    end

    # Resolve the URL, follows redirects.
    # @return [String] the resolved URL.
    # @param [String] url to retrieve.
    # @example Resolve example.com and request
    #    Request.resolve_url('example.com')
    def self.resolve_url(url)
      resolved = UrlResolver.resolve(url)
      resolved = resolved.prepend('http://') unless protocol?(resolved)
      resolved
    end

    # Resolve the URL, follows redirects.
    # @return [Boolean] true if string includes protocol.
    # @param [String] url to check.
    # @example Check if string includes protocol
    #    Request.protocol?('example.com')
    #    # => false
    #    Request.protocol?('https://example.com')
    #    # => true
    #    Request.protocol?('http://example.com')
    #    # => true
    def self.protocol?(url)
      url.start_with?('http://') || url.start_with?('https://')
    end
  end
end
