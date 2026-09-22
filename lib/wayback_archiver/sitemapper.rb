require 'set'
require 'webrobots'

require 'wayback_archiver/sitemap'
require 'wayback_archiver/request'

module WaybackArchiver
  # Fetch and parse sitemaps recursively
  # @api private
  class Sitemapper
    # Raised when a fetched document parses but isn't a sitemap at all.
    #
    # A Request::ServerError because it means the same thing as the other
    # payload-validity errors in this gem (bad JSON from SPN2, an unexpected
    # CDX shape): the server answered, but with something unusable. Callers
    # that already rescue Request::Error therefore handle it — the CLI maps
    # it to exit 4, and autodiscovery falls back to crawling.
    class InvalidSitemapError < Request::ServerError; end

    # Common locations for Sitemap(s)
    COMMON_SITEMAP_LOCATIONS = %w[
      sitemap_index.xml.gz
      sitemap-index.xml.gz
      sitemap_index.xml
      sitemap-index.xml
      sitemap.xml.gz
      sitemap.xml
    ].freeze

    # Autodiscover the location of the Sitemap, then fetch and parse recursively.
    # First it tries /robots.txt, then common locations for Sitemap and finally the supplied URL.
    # @return [Array<String>] of URLs defined in Sitemap(s).
    # @param [URI] url to domain.
    # @example Get URLs defined in Sitemap for google.com
    #    Sitemapper.autodiscover('https://google.com/')
    # @see http://www.sitemaps.org
    def self.autodiscover(url)
      url = Request.build_uri(url).to_s
      # One line for the whole probe. Narrating robots.txt plus six common
      # locations individually was most of the output on any site without a
      # sitemap; the detail stays at debug for when you need to see which
      # location answered.
      WaybackArchiver.logger.info "Looking for a Sitemap for #{url}"
      WaybackArchiver.logger.debug 'Looking for Sitemap(s) in /robots.txt'
      robots = WebRobots.new(WaybackArchiver.config.user_agent)
      sitemaps = robots.sitemaps(url)

      if sitemaps.any?
        return sitemaps.flat_map do |sitemap|
          WaybackArchiver.logger.info "Sitemap found at #{sitemap} (declared in robots.txt)"
          urls(url: sitemap)
        end
      end

      COMMON_SITEMAP_LOCATIONS.each do |path|
        WaybackArchiver.logger.debug "Looking for Sitemap at #{path}"
        sitemap_url = [url, path].join(url.end_with?('/') ? '' : '/')
        response = Request.get(sitemap_url, raise_on_http_error: false)
        next unless response.success?

        begin
          found = urls(xml: response.body)
        rescue InvalidSitemapError => e
          # A 200 that isn't a sitemap — catch-all routes on SPAs answer every
          # path with the homepage. Keep probing the remaining locations.
          WaybackArchiver.logger.debug "Not a Sitemap at #{sitemap_url}: #{e.message}"
          next
        end

        WaybackArchiver.logger.info "Sitemap found at #{sitemap_url}"
        return found
      end

      WaybackArchiver.logger.debug "Looking for Sitemap at #{url}"
      urls(url: url)
    rescue Request::Error => e
      # autodiscover is the auto-cascade probe: not finding a sitemap here is
      # the expected outcome for most sites, not a failure — the caller falls
      # back to crawling, which is why this is info rather than error. The
      # explicit sitemap strategy (Sitemapper.urls) raises instead.
      WaybackArchiver.logger.info "No Sitemap found at #{url} (#{describe_failure(e)}) - falling back to crawling"
      []
    end

    # One short phrase for why the probe came up empty. The raw exception read
    # as "Error raised when requesting X, <ClassName>, Failed with response
    # code: 404 when requesting Y" — the reason twice, a class name, and a
    # redirect target instead of the URL the user asked for.
    def self.describe_failure(error)
      case error
      when InvalidSitemapError    then 'not a sitemap'
      when Request::ResponseError then error.code ? "HTTP #{error.code}" : 'HTTP error'
      else error.message
      end
    end
    private_class_method :describe_failure

    # Fetch and parse sitemaps recursively.
    # @return [Array<String>] of URLs defined in Sitemap(s).
    # @param url [String] URL to Sitemap.
    # @param xml [String] Sitemap XML.
    # @example Get URLs defined in Sitemap for google.com
    #    Sitemapper.urls(url: 'https://google.com/sitemap.xml')
    # @example Get URLs defined in Sitemap
    #    Sitemapper.urls(xml: xml)
    # @see http://www.sitemaps.org
    def self.urls(url: nil, xml: nil, visited: Set.new)
      if visited.include?(url)
        WaybackArchiver.logger.debug "Already visited #{url} skipping.."
        return []
      end

      visited << url if url

      # raise_on_http_error: a 404 sitemap used to be parsed as empty XML and
      # reported as "0 URLs found", so a typo in --sitemap looked like a
      # successful run that archived nothing.
      xml = Request.get(url, raise_on_http_error: true).body unless xml
      sitemap = Sitemap.new(xml)

      unless sitemap.valid?
        raise InvalidSitemapError,
              "Response is not a sitemap#{" (#{url})" if url}: expected a <urlset>, " \
              "<sitemapindex> or plain-text URL list, got #{describe_document(sitemap)}"
      end

      if sitemap.sitemap_index?
        sitemap.sitemaps.flat_map do |sitemap_url|
          urls(url: sitemap_url, visited: visited)
        rescue Request::Error => e
          # One bad child shouldn't sink an otherwise good index.
          WaybackArchiver.logger.warn "Skipping sitemap #{sitemap_url}: #{e.message}"
          []
        end
      else
        sitemap.urls.map { |url| url&.strip }
      end
    end

    # Short description of what we got instead, for the error message.
    def self.describe_document(sitemap)
      root = sitemap.root_name
      return "<#{root}>" if root

      sitemap.plain_document? ? 'a non-XML document' : 'an unrecognised document'
    end
    private_class_method :describe_document
  end
end
