require 'set'
require 'nokogiri'

module WaybackArchiver
  class Crawler
    CRAWLER_INFO_LINK = 'https://rubygems.org/gems/wayback_archiver'
    HEADERS_HASH      = {
      'User-Agent' => "WaybackArchiver/#{VERSION} (+#{CRAWLER_INFO_LINK})"
    }

    def initialize(url, resolve = false)
      base_url     = Request.resolve_url(url)
      @options     = { resolve: resolve }
      @crawl_url   = CrawlUrl.new(base_url)
      @fetch_queue = Set.new
      @procesed    = Set.new
      @fetch_queue << @crawl_url.resolved_base_url
    end

    def self.collect_urls(base_url)
      new(base_url).collect_urls
    end

    def collect_urls
      until @fetch_queue.empty?
        url = @fetch_queue.first
        @fetch_queue.delete(@fetch_queue.first)
        page_links(url)
      end
      puts "Crawling finished, #{@procesed.length} links found"
      @procesed.to_a
    rescue Interrupt, IRB::Abort
      puts 'Crawl interrupted.'
      @fetch_queue.to_a
    end

    private

    def page_links(get_url)
      puts "Queue length: #{@fetch_queue.length}, Parsing: #{get_url}"
      link_elements = Request.get_page(get_url).css('a') rescue []
      @procesed << get_url
      link_elements.each do |page_link|
        absolute_url = @crawl_url.absolute_url_from(page_link.attr('href'), get_url)
        if absolute_url
          resolved_url = resolve(absolute_url)
          @fetch_queue << resolved_url if !@procesed.include?(resolved_url)
        end
      end
    end

    def resolve(url)
      @options[:resolve] ? Request.resolve_url(url) : url
    end
  end
end
