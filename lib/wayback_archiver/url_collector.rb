require 'robots'

module WaybackArchiver
  # Retrive URLs from different sources
  class UrlCollector
    class << self
      # Retrieve URLs from Sitemap.
      # @return [Array] of URLs defined in Sitemap.
      # @param [String] url domain to retrieve Sitemap from.
      # @example Get URLs defined in Sitemap for google.com
      #    UrlCollector.sitemap('https://google.com')
      def sitemap(url)
        resolved = Request.resolve_url("#{url}/sitemap.xml")
        sitemap  = Request.document(resolved)
        sitemap.css('loc').map { |element| element.text }
      end

      # Retrieve URLs by crawling.
      # @return [Array] of URLs defined found during crawl.
      # @param [String] url domain to crawl URLs from.
      # @example Crawl URLs defined on example.com
      #    UrlCollector.crawl('http://example.com')
      def crawl(url)
        robots = ::Robots.new(WaybackArchiver::USER_AGENT)
        urls = []
        Spidr.site(url, ignore_exts: %w(js css jpg jpeg gif png txt)) do |spider|
          spider.visit_urls_like { |url| robots.allowed?(url) ? true : false }

          spider.every_url do |found_url|
            url = found_url.to_s
            urls << url
            yield(url) if block_given?
          end
        end
        urls
      end

      # Retrieve URLs listed in file.
      # @return [Array] of URLs defined in file.
      # @param [String] path to get URLs from.
      # @example Get URLs defined in /path/to/file
      #    UrlCollector.file('/path/to/file')
      def file(path)
        raise ArgumentError, "No such file: #{path}" unless File.exist?(path)
        urls = []
        File.open(path).read
          .gsub(/\r\n?/, "\n")
          .each_line { |line| urls << line.gsub(/\n/, '').strip }
        urls.reject(&:empty?)
      end
    end
  end
end
