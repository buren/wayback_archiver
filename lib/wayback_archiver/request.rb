require 'url_resolver' # TODO: Allow users to use any resolver

module WaybackArchiver
  class Request
    INFO_LINK  = 'https://rubygems.org/gems/wayback_archiver'
    USER_AGENT = "WaybackArchiver/#{VERSION} (+#{INFO_LINK})"

    class << self
      def get_page(url, document_type = :html)
        response = Request.get_response(url).body
        case document_type
        when :xml
          Nokogiri::XML(response)
        else
          Nokogiri::HTML(response)
        end
      end

      def get_response(url, resolve = false)
        resolved_url = resolve ? resolve_url(url) : url
        uri          = URI.parse(resolved_url)
        http         = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true if resolved_url.include?('https://')

        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = USER_AGENT
        http.request(request)
      end

      def resolve_url(url)
        UrlResolver.resolve(url)
      end
    end
  end
end
