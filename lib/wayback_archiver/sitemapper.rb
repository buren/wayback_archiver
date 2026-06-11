require 'set'
require 'webrobots'

require 'wayback_archiver/sitemap'
require 'wayback_archiver/request'

module WaybackArchiver
  # Fetch and parse sitemaps recursively
  # @api private
  class Sitemapper
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
      WaybackArchiver.logger.info 'Looking for Sitemap(s) in /robots.txt'
      robots = WebRobots.new(WaybackArchiver.config.user_agent)
      sitemaps = robots.sitemaps(url)

      if sitemaps.any?
        return sitemaps.flat_map do |sitemap|
          WaybackArchiver.logger.info "Fetching Sitemap at #{sitemap}"
          urls(url: sitemap)
        end
      end

      COMMON_SITEMAP_LOCATIONS.each do |path|
        WaybackArchiver.logger.info "Looking for Sitemap at #{path}"
        sitemap_url = [url, path].join(url.end_with?('/') ? '' : '/')
        response = Request.get(sitemap_url, raise_on_http_error: false)

        if response.success?
          WaybackArchiver.logger.info "Sitemap found at #{sitemap_url}"
          return urls(xml: response.body)
        end
      end

      WaybackArchiver.logger.info "Looking for Sitemap at #{url}"
      urls(url: url)
    rescue Request::Error => e
      # autodiscover is the auto-cascade probe: a network failure here means
      # 'no sitemap found' and the caller falls back to crawling. The explicit
      # sitemap strategy (Sitemapper.urls) lets the error propagate instead.
      WaybackArchiver.logger.error "Error raised when requesting #{url}, #{e.class}, #{e.message}"
      []
    end

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

      xml = Request.get(url).body unless xml
      sitemap = Sitemap.new(xml)

      if sitemap.sitemap_index?
        sitemap.sitemaps.flat_map do |sitemap_url|
          urls(url: sitemap_url, visited: visited)
        end
      else
        sitemap.urls.map { |url| url&.strip }
      end
    end
  end
end
