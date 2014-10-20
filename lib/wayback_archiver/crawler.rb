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
      puts 'Crawling urls'
      until @fetch_queue.empty?
        url = @fetch_queue.first
        @fetch_queue.delete(@fetch_queue.first)
        @procesed << url
        page_links(url).each do |page_url|
          @fetch_queue << page_url unless @procesed.include?(page_url)
        end
      end
      puts "Crawling finished, #{@procesed.length
      } links found"
      @procesed
    end

    def page_links(url)
      puts "Queue length: #{@fetch_queue.length}, #{url}"
      links = Nokogiri::HTML(open(url)).css('a') rescue []
      links.map    { |link| link.attr('href') }
           .map    { |link| sanitize_url(link) }
           .reject { |link| link.nil? }
    end

    def sanitize_url(raw_url)
      url = URI.parse(raw_url) rescue URI.parse('')  
      if url.host.nil?
        "#{@base_url}#{url.path}?#{url.query}"
      else
        raw_url if raw_url.include?(@base_url)
      end
    end
  end
end
