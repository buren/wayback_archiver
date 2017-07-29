require 'robots'

require 'wayback_archiver/sitemap'
require 'wayback_archiver/request'

module WaybackArchiver
  # Fetch and parse sitemaps recursively
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
      WaybackArchiver.logger.info 'Looking for Sitemap(s) in /robots.txt'
      robots = Robots.new(WaybackArchiver.user_agent)
      sitemaps = robots.other_values(url)['Sitemap']
      if sitemaps
        return sitemaps.flat_map do |sitemap|
          WaybackArchiver.logger.info "Fetching Sitemap at #{sitemap}"
          urls(url: sitemap)
        end
      end

      COMMON_SITEMAP_LOCATIONS.each do |path|
        WaybackArchiver.logger.info "Looking for Sitemap at #{path}"
        sitemap_url = [url, path].join(url.end_with?('/') ? '' : '/')
        response = Request.get(sitemap_url, raise_on_http_error: false)
        return urls(xml: response.body) if response.success?
      end

      WaybackArchiver.logger.info "Looking for Sitemap at #{url}"
      urls(url: url)
    rescue Request::Error => e
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
    def self.urls(url: nil, xml: nil)
      xml = Request.get(url).body unless xml
      sitemap = Sitemap.new(xml)

      if sitemap.sitemap_index?
        sitemap.sitemaps.flat_map { |sitemap_url| urls(url: sitemap_url) }
      else
        sitemap.urls
      end
    rescue Request::Error => e
      WaybackArchiver.logger.error "Error raised when requesting #{url}, #{e.class}, #{e.message}"

      []
    end
  end
end
