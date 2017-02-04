require 'uri'
require 'net/http'

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

  # Send URLs to Wayback Machine.
  # @return [Array] with URLs sent to the Wayback Machine.
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
    when 'file'    then Archive.post(UrlCollector.file(source))
    when 'crawl'   then UrlCollector.crawl(source) { |url| Archive.post_url(url) }
    when 'sitemap' then Archive.post(UrlCollector.sitemap(source))
    when 'url'     then Archive.post_url(Request.resolve_url(source))
    else
      raise ArgumentError, "Unknown type: '#{type}'. Allowed types: sitemap, url, file, crawl"
    end
  end
end
