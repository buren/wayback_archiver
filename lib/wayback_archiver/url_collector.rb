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
    # @example Crawl URLs defined on example.com and limit the number of visited pages to 100
    #    URLCollector.crawl('http://example.com', limit: 100)
    # @example Crawl URLs defined on example.com and explicitly set no upper limit on the number of visited pages to 100
    #    URLCollector.crawl('http://example.com', limit: -1)
    def self.crawl(url, limit: WaybackArchiver.max_limit)
      urls = []
      start_at_url = Request.build_uri(url).to_s
      options = {
        robots: false,
        user_agent: WaybackArchiver.user_agent
      }
      options[:limit] = limit unless limit == -1

      Spidr.site(start_at_url, options) do |spider|
        spider.every_page do |page|
          sleep(3)
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
