require 'set'
require 'nokogiri'   
require 'open-uri'

module WaybackArchiver
  class Crawler
    def initialize(base_url)
      @base_url    = base_url
      @hostname    = URI.parse(@base_url).host
      @fetch_queue = Set.new
      @procesed    = Set.new
      @fetch_queue << @base_url
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
    end

    def page_links(url)
      puts "Queue length: #{@fetch_queue.length}, Parsing: #{url}"
      link_elements = Nokogiri::HTML(open(url)).css('a') rescue []
      @procesed << url
      link_elements.each do |link|
        href = sanitize_url(link.attr('href'))
        @fetch_queue << href if href && !@procesed.include?(href)
      end
    end

    def sanitize_url(raw_url)
      url = URI.parse(raw_url) rescue URI.parse('')  
      if url.host.nil?
        sanitized_url  = "#{@base_url}#{url.path}"
        sanitized_url += "?#{url.query}" unless url.query.nil?
        sanitized_url
      else
        raw_url if raw_url.include?(@base_url) && @hostname.eql?(url.hostname)
      end
    end
  end
end
