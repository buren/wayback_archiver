require 'wayback_archiver/sitemap'

module WaybackArchiver
  # Fetch and parse sitemaps recursively
  class Sitemapper
    # Fetch and parse sitemaps recursively.
    # @return [Array] of URLs defined in Sitemap(s).
    # @param [String] url to Sitemap.
    # @example Get URLs defined in Sitemap for google.com
    #    Sitemapper.urls('https://google.com/sitemap.xml')
    def self.urls(url)
      xml = Request.response(url).body
      sitemap = Sitemap.new(xml)

      if sitemap.sitemap_index?
        sitemap.sitemaps.flat_map { |sitemap_url| urls(sitemap_url) }
      else
        sitemap.urls
      end
    end
  end
end
