require 'spidr'

require 'wayback_archiver/sitemapper'
require 'wayback_archiver/feed_parser'
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

    # Retrieve URLs from an RSS or Atom feed.
    # @return [Array<String>] of URLs found in the feed.
    # @param [String] url to the RSS or Atom feed.
    # @example Get URLs from an RSS feed
    #    URLCollector.feed('https://example.com/feed.xml')
    def self.feed(url)
      FeedParser.urls(url: Request.build_uri(url).to_s)
    end

    # Retrieve URLs by crawling.
    # @return [Array<String>] of URLs defined found during crawl.
    # @param [String] url domain to crawl URLs from.
    # @param [Array<String, Regexp>] hosts to crawl.
    # @example Crawl URLs defined on example.com
    #    URLCollector.crawl('http://example.com')
    # @example Crawl URLs defined on example.com and limit the number of visited pages to 100
    #    URLCollector.crawl('http://example.com', limit: 100)
    # @example Crawl URLs defined on example.com and explicitly set no upper limit on the number of visited pages to 100
    #    URLCollector.crawl('http://example.com', limit: -1)
    # @example Crawl multiple hosts
    #    URLCollector.crawl(
    #      'http://example.com',
    #      hosts: [
    #        'example.com',
    #        /host[\d]+\.example\.com/
    #      ]
    #    )
    def self.crawl(url, hosts: [], limit: WaybackArchiver.max_limit)
      urls = []
      start_at_url = resolve_start_url(Request.build_uri(url).to_s)
      options = {
        robots: WaybackArchiver.respect_robots_txt,
        hosts: hosts,
        user_agent: WaybackArchiver.user_agent
      }
      options[:limit] = limit unless limit == -1

      Spidr.site(start_at_url, **options) do |spider|
        spider.every_page do |page|
          page_url = page.url.to_s
          urls << page_url
          WaybackArchiver.logger.debug "Found: #{page_url}"
          yield(page_url) if block_given?
        end
      end
      urls
    end

    # Resolve a start URL through redirects so Spidr sees the final host.
    # e.g. http://abclabs.se -> https://www.abclabs.se
    def self.resolve_start_url(url)
      response = Request.get(url, follow_redirects: true, raise_on_http_error: false)
      response.uri && !response.uri.empty? ? response.uri : url
    rescue Request::Error
      url
    end
    private_class_method :resolve_start_url
  end
end
