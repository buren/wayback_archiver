require 'uri'
require 'net/http'

require 'concurrent'

require 'wayback_archiver/null_logger'
require 'wayback_archiver/version'
require 'wayback_archiver/url_collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/request'

# WaybackArchiver, send URLs to Wayback Machine. By crawling, sitemap, file or single URL.
module WaybackArchiver
  # Link to gem on rubygems.org, part of the sent User-Agent
  INFO_LINK  = 'https://rubygems.org/gems/wayback_archiver'.freeze
  # WaybackArchiver User-Agent
  USER_AGENT = "WaybackArchiver/#{WaybackArchiver::VERSION} (+#{INFO_LINK})".freeze

  class UnknownSourceTypeError < ::ArgumentError;end

  # Send URLs to Wayback Machine.
  # @return [Array] of URLs sent to the Wayback Machine.
  # @param [String] source for URL(s).
  # @param [String/Symbol] type of source. Supported types: ['crawl', 'sitemap', 'url', 'file'].
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.archive('example.com') # Default type is :crawl
  #    WaybackArchiver.archive('example.com', :crawl)
  # @example Send only example.com
  #    WaybackArchiver.archive('example.com', :url)
  # @example Send URL on each line in specified file
  #    WaybackArchiver.archive('/path/to/file', :file)
  def self.archive(source, type = :crawl)
    case type.to_s
    when 'file'    then file(source)
    when 'crawl'   then crawl(source)
    when 'sitemap' then sitemap(source)
    when 'urls'    then urls(source)
    when 'url'     then urls(source)
    else
      raise UnknownSourceTypeError.new("Unknown type: '#{type}'. Allowed types: sitemap, urls, url, file, crawl")
    end
  end

  # Crawl site for URLs to send to the Wayback Machine.
  # @return [Array] of URLs sent to the Wayback Machine.
  # @param [String] source for URL(s).
  # @param [Integer] concurrency.
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.crawl('example.com') # Default concurrency is 5
  # @example Crawl example.com and send all URLs of the same domain with low concurrency
  #    WaybackArchiver.crawl('example.com', concurrency: 1)
  def self.crawl(source, concurrency: Archive::DEFAULT_CONCURRENCY)
    Archive.crawl(source, concurrency: concurrency)
  end

  # Get URLs from sitemap and send found URLs to the Wayback Machine.
  # @return [Array] of URLs sent to the Wayback Machine.
  # @param [String] source of sitemap.
  # @param [Integer] concurrency.
  # @example Get example.com sitemap and archive all found URLs
  #    WaybackArchiver.sitemap('example.com') # Default concurrency is 5
  # @example Get example.com sitemap and archive all found URLs with low concurrency
  #    WaybackArchiver.sitemap('example.com', concurrency: 1)
  def self.sitemap(source, concurrency: Archive::DEFAULT_CONCURRENCY)
    Archive.post(UrlCollector.sitemap(source), concurrency: concurrency)
  end

  # Send URL to the Wayback Machine.
  # @return [Array] of URLs sent to the Wayback Machine.
  # @param [Array] of URLs.
  # @param [Integer] concurrency.
  # @example Archive example.com
  #    WaybackArchiver.urls('example.com')
  # @example Archive example.com and google.com
  #    WaybackArchiver.urls(%w(example.com google.com))
  def self.urls(urls, concurrency: Archive::DEFAULT_CONCURRENCY)
    Archive.post(Array(urls), concurrency: concurrency)
  end

  # Send URLs in file to the Wayback Machine.
  # @return [Array] of URLs sent to the Wayback Machine.
  # @param [String] of sitemap.
  # @param [Integer] concurrency.
  # @example Archive all URLs in file
  #    WaybackArchiver.file('/path/to/file')
  # @example Archive all URLs in file with low concurrency
  #    WaybackArchiver.file(('/path/to/file', concurrency: 1)
  def self.file(urls, concurrency: Archive::DEFAULT_CONCURRENCY)
    Archive.post(UrlCollector.file(source))
  end

  def self.logger=(logger)
    @logger = logger
  end

  def self.logger
    @logger ||= NullLogger.new
  end
end
