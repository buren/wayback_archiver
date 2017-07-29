require 'spidr'
require 'robots'

require 'wayback_archiver/sitemapper'
require 'wayback_archiver/request'

module WaybackArchiver
  # Retrive URLs from different sources
  class URLCollector
    # Retrieve URLs from Sitemap.
    # @return [Array<String>] of URLs defined in Sitemap.
    # @param [String] url domain to retrieve Sitemap from.
    # @example Get URLs defined in Sitemap for google.com
    #    URLCollector.sitemap('https://google.com/sitemap.xml')
    def self.sitemap(url)
      Sitemapper.urls(url: Request.build_uri(url))
    end

    # Retrieve URLs by crawling.
    # @return [Array<String>] of URLs defined found during crawl.
    # @param [String] url domain to crawl URLs from.
    # @example Crawl URLs defined on example.com
    #    URLCollector.crawl('http://example.com')
    def self.crawl(url)
      urls = []
      start_at_url = Request.build_uri(url).to_s
      options = {
        robots: true,
        user_agent: WaybackArchiver.user_agent
      }
      Spidr.site(start_at_url, options) do |spider|
        spider.every_html_page do |page|
          page_url = page.url.to_s
          urls << page_url
          WaybackArchiver.logger.debug "Found: #{page_url}"
          yield(page_url) if block_given?
        end
      end
      urls
    end
  end
end
