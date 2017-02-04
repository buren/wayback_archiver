require 'spidr'
require 'robots'

module WaybackArchiver
  # Retrive URLs from different sources
  class UrlCollector
    # Retrieve URLs from Sitemap.
    # @return [Array] of URLs defined in Sitemap.
    # @param [String] url domain to retrieve Sitemap from.
    # @example Get URLs defined in Sitemap for google.com
    #    UrlCollector.sitemap('https://google.com')
    def self.sitemap(url)
      resolved = Request.resolve_url("#{url}/sitemap.xml")
      sitemap  = Request.document(resolved)
      sitemap.css('loc').map(&:text)
    end

    # Retrieve URLs by crawling.
    # @return [Array] of URLs defined found during crawl.
    # @param [String] url domain to crawl URLs from.
    # @example Crawl URLs defined on example.com
    #    UrlCollector.crawl('http://example.com')
    def self.crawl(url)
      urls = []
      resolved_url = Request.resolve_url(url)
      Spidr.site(resolved_url, robots: true) do |spider|
        spider.every_html_page do |page|
          page_url = page.url.to_s
          urls << page_url
          yield(page_url) if block_given?
        end
      end
      urls
    end

    # Retrieve URLs listed in file.
    # @return [Array] of URLs defined in file.
    # @param [String] path to get URLs from.
    # @example Get URLs defined in /path/to/file
    #    UrlCollector.file('/path/to/file')
    def self.file(path)
      raise ArgumentError, "No such file: #{path}" unless File.exist?(path)
      urls = []
      File.open(path).read
          .gsub(/\r\n?/, "\n")
          .each_line { |line| urls << line.delete("\n").strip }
      urls.reject(&:empty?)
    end
  end
end
