require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/retry'
require 'wayback_archiver/thread_pool'
require 'wayback_archiver/null_logger'
require 'wayback_archiver/listener'
require 'wayback_archiver/configuration'
require 'wayback_archiver/version'
require 'wayback_archiver/url_collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/cdx'
require 'wayback_archiver/check_result'
require 'wayback_archiver/screenshot'
require 'wayback_archiver/sitemapper'
require 'wayback_archiver/feed_parser'

# WaybackArchiver, send URLs to Wayback Machine. By crawling, sitemap or by passing a list of URLs.
module WaybackArchiver
  # Link to gem on rubygems.org, part of the sent User-Agent
  INFO_LINK  = 'https://rubygems.org/gems/wayback_archiver'.freeze
  # WaybackArchiver User-Agent
  USER_AGENT = "WaybackArchiver/#{WaybackArchiver::VERSION} (+#{INFO_LINK})".freeze
  # Default for whether to respect robots txt files
  DEFAULT_RESPECT_ROBOTS_TXT = false

  # Default concurrency for archiving URLs (SPN2 rate limit: 12/min)
  DEFAULT_CONCURRENCY = 4

  # Maxmium number of links posted (-1 is no limit)
  DEFAULT_MAX_LIMIT = -1

  # Send URLs to Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String/Array<String>] source for URL(s).
  # @param [String/Symbol] strategy of source. Supported strategies: crawl, sitemap, url, urls, rss, auto.
  # @param [Array<String, Regexp>] hosts to crawl.
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.archive('example.com') # Default strategy is :auto
  #    WaybackArchiver.archive('example.com', strategy: :auto)
  #    WaybackArchiver.archive('example.com', strategy: :auto, concurrency: 10)
  #    WaybackArchiver.archive('example.com', strategy: :auto, limit: 100) # send max 100 URLs
  #    WaybackArchiver.archive('example.com', :auto)
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.archive('example.com', strategy: :crawl)
  #    WaybackArchiver.archive('example.com', strategy: :crawl, concurrency: 10)
  #    WaybackArchiver.archive('example.com', strategy: :crawl, limit: 100) # send max 100 URLs
  #    WaybackArchiver.archive('example.com', :crawl)
  # @example Send example.com Sitemap URLs
  #    WaybackArchiver.archive('example.com', strategy: :sitemap)
  #    WaybackArchiver.archive('example.com', strategy: :sitemap, concurrency: 10)
  #    WaybackArchiver.archive('example.com', strategy: :sitemap, limit: 100) # send max 100 URLs
  #    WaybackArchiver.archive('example.com', :sitemap)
  # @example Send only example.com
  #    WaybackArchiver.archive('example.com', strategy: :url)
  #    WaybackArchiver.archive('example.com', strategy: :url, concurrency: 10)
  #    WaybackArchiver.archive('example.com', strategy: :url, limit: 100) # send max 100 URLs
  #    WaybackArchiver.archive('example.com', :url)
  # @example Crawl multiple hosts
  #    WaybackArchiver.archive(
  #      'http://example.com',
  #      hosts: [
  #        'example.com',
  #        /host[\d]+\.example\.com/
  #      ]
  #    )
  def self.archive(source, legacy_strategy = nil, strategy: :auto, hosts: [], concurrency: config.concurrency, limit: config.max_limit, skip_urls: nil, **options, &block)
    strategy = legacy_strategy || strategy

    case strategy.to_s
    when 'crawl'   then crawl(source, concurrency: concurrency, limit: limit, hosts: hosts, skip_urls: skip_urls, **options, &block)
    when 'auto'    then auto(source, concurrency: concurrency, limit: limit, hosts: hosts, skip_urls: skip_urls, **options, &block)
    when 'sitemap' then sitemap(source, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    when 'urls'    then urls(source, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    when 'url'     then urls(source, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    when 'rss'     then rss(source, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    else
      raise ArgumentError, "Unknown strategy: '#{strategy}'. Allowed strategies: sitemap, urls, url, crawl, rss"
    end
  end

  # Look for Sitemap(s) and if nothing is found fallback to crawling.
  # Then send found URLs to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] source (must be a valid URL).
  # @param concurrency [Integer]
  # @example Auto archive example.com
  #    WaybackArchiver.auto('example.com') # Default concurrency is 1
  # @example Auto archive example.com with low concurrency
  #    WaybackArchiver.auto('example.com', concurrency: 1)
  # @example Auto archive example.com and archive max 100 URLs
  #    WaybackArchiver.auto('example.com', limit: 100)
  # @see http://www.sitemaps.org
  def self.auto(source, concurrency: config.concurrency, limit: config.max_limit, hosts: [], skip_urls: nil, **options, &block)
    # Step 1: Fetch source URL and check if it is itself a feed
    WaybackArchiver.logger.info "Fetching #{source}"
    begin
      response = Request.get(source, raise_on_http_error: false)
      source_body = response.success? ? response.body : nil
    rescue Request::Error => e
      WaybackArchiver.logger.error "Error fetching #{source}: #{e.message}"
      source_body = nil
    end

    if source_body
      feed_urls = FeedParser.urls(xml: source_body)
      if feed_urls.any?
        WaybackArchiver.listener.on_resolved(strategy: :feed, url_count: feed_urls.length, source: source)
        return Archive.post(feed_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
      end
    end

    # Step 2: Try sitemap autodiscovery
    sitemap_urls = Sitemapper.autodiscover(source)
    if sitemap_urls.any?
      WaybackArchiver.listener.on_resolved(strategy: :sitemap, url_count: sitemap_urls.length, source: source)
      return Archive.post(sitemap_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    end

    # Step 3: Try feed autodiscovery (HTML link tags + common feed paths)
    feed_urls = FeedParser.autodiscover(source, html: source_body)
    if feed_urls.any?
      WaybackArchiver.listener.on_resolved(strategy: :feed, url_count: feed_urls.length, source: source)
      return Archive.post(feed_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    end

    # Step 4: Crawl
    WaybackArchiver.listener.on_resolved(strategy: :crawl, url_count: nil, source: source)
    WaybackArchiver.logger.info "Crawling #{source}"
    Archive.crawl(source, hosts: hosts, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Crawl site for URLs to send to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] url to start crawling from.
  # @param [Array<String, Regexp>] hosts to crawl
  # @param concurrency [Integer]
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.crawl('example.com') # Default concurrency is 1
  # @example Crawl example.com and send all URLs of the same domain with low concurrency
  #    WaybackArchiver.crawl('example.com', concurrency: 1)
  # @example Crawl example.com and archive max 100 URLs
  #    WaybackArchiver.crawl('example.com', limit: 100)
  # @example Crawl multiple hosts
  #    URLCollector.crawl(
  #      'http://example.com',
  #      hosts: [
  #        'example.com',
  #        /host[\d]+\.example\.com/
  #      ]
  #    )
  def self.crawl(url, hosts: [], concurrency: config.concurrency, limit: config.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Crawling #{url}"
    WaybackArchiver.listener.on_resolved(strategy: :crawl, url_count: nil, source: url)
    Archive.crawl(url, hosts: hosts, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Get URLs from sitemap and send found URLs to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] url to the sitemap.
  # @param concurrency [Integer]
  # @example Get example.com sitemap and archive all found URLs
  #    WaybackArchiver.sitemap('example.com/sitemap.xml') # Default concurrency is 1
  # @example Get example.com sitemap and archive all found URLs with low concurrency
  #    WaybackArchiver.sitemap('example.com/sitemap.xml', concurrency: 1)
  # @example Get example.com sitemap archive max 100 URLs
  #    WaybackArchiver.sitemap('example.com/sitemap.xml', limit: 100)
  # @see http://www.sitemaps.org
  def self.sitemap(url, concurrency: config.concurrency, limit: config.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Fetching Sitemap"
    discovered_urls = URLCollector.sitemap(url)
    WaybackArchiver.listener.on_resolved(strategy: :sitemap, url_count: discovered_urls.length, source: url)
    Archive.post(discovered_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Get URLs from an RSS or Atom feed and send them to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] url to the RSS or Atom feed.
  # @param concurrency [Integer]
  # @example Archive all URLs from an RSS feed
  #    WaybackArchiver.rss('https://example.com/feed.xml')
  # @example Archive RSS feed URLs with concurrency
  #    WaybackArchiver.rss('https://example.com/feed.xml', concurrency: 2)
  # @example Archive RSS feed URLs with a limit
  #    WaybackArchiver.rss('https://example.com/feed.xml', limit: 10)
  def self.rss(url, concurrency: config.concurrency, limit: config.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Fetching RSS/Atom feed"
    discovered_urls = URLCollector.feed(url)
    WaybackArchiver.listener.on_resolved(strategy: :rss, url_count: discovered_urls.length, source: url)
    Archive.post(discovered_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Send URL to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [Array<String>/String] urls or url.
  # @param concurrency [Integer]
  # @example Archive example.com
  #    WaybackArchiver.urls('example.com')
  # @example Archive example.com and google.com
  #    WaybackArchiver.urls(%w(example.com google.com))
  # @example Archive example.com, max 100 URLs
  #    WaybackArchiver.urls(%w(example.com www.example.com), limit: 100)
  def self.urls(urls, concurrency: config.concurrency, limit: config.max_limit, skip_urls: nil, **options, &block)
    urls_array = Array(urls)
    WaybackArchiver.listener.on_resolved(strategy: :urls, url_count: urls_array.length, source: nil)
    Archive.post(urls_array, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Discover URLs using the specified strategy without archiving them.
  # @return [Array<String>] discovered URLs
  # @param [String/Array<String>] source for URL(s).
  # @param [String/Symbol] strategy for URL discovery.
  # @param [Array<String, Regexp>] hosts to crawl (crawl strategy only).
  # @param [Integer] limit max number of URLs.
  def self.discover_urls(source, strategy: 'auto', hosts: [], limit: config.max_limit)
    case strategy.to_s
    when 'urls', 'url'
      Array(source)
    when 'sitemap'
      URLCollector.sitemap(source)
    when 'rss'
      URLCollector.feed(source)
    when 'crawl'
      URLCollector.crawl(source, hosts: hosts, limit: limit)
    when 'auto'
      discover_urls_auto(source, hosts: hosts, limit: limit)
    else
      raise ArgumentError, "Unknown strategy: '#{strategy}'"
    end
  end

  # Check which URLs are already archived in the Wayback Machine.
  # @return [Array<CheckResult>] check results for each URL.
  # @param [Array<String>] urls to check.
  # @param [Integer] concurrency number of concurrent CDX requests.
  # @yield [CheckResult] each result as it completes.
  def self.check(urls, concurrency: config.concurrency, &block)
    CDX.check_urls(urls, concurrency: concurrency, &block)
  end

  # Auto-discover URLs without archiving (mirrors the auto strategy logic).
  def self.discover_urls_auto(source, hosts: [], limit: config.max_limit)
    WaybackArchiver.logger.info "Fetching #{source}"
    begin
      response = Request.get(source, raise_on_http_error: false)
      source_body = response.success? ? response.body : nil
    rescue Request::Error
      source_body = nil
    end

    if source_body
      feed_urls = FeedParser.urls(xml: source_body)
      if feed_urls.any?
        WaybackArchiver.logger.info "Strategy resolved: feed (#{feed_urls.length} URLs)"
        return feed_urls
      end
    end

    sitemap_urls = Sitemapper.autodiscover(source)
    if sitemap_urls.any?
      WaybackArchiver.logger.info "Strategy resolved: sitemap (#{sitemap_urls.length} URLs)"
      return sitemap_urls
    end

    feed_urls = FeedParser.autodiscover(source, html: source_body)
    if feed_urls.any?
      WaybackArchiver.logger.info "Strategy resolved: feed (#{feed_urls.length} URLs)"
      return feed_urls
    end

    WaybackArchiver.logger.info "Strategy resolved: crawl"
    URLCollector.crawl(source, hosts: hosts, limit: limit)
  end
  private_class_method :discover_urls_auto

  # Returns the configuration object.
  # @return [Configuration]
  def self.config
    @config ||= Configuration.new
  end

  # Configure WaybackArchiver with a block.
  # @yield [Configuration] the configuration object.
  # @return [Configuration]
  # @example
  #   WaybackArchiver.configure do |config|
  #     config.access_key = 'your-access-key'
  #     config.secret_key = 'your-secret-key'
  #     config.concurrency = 8
  #   end
  def self.configure
    yield config
    config
  end

  # Convenience delegates — avoids verbose WaybackArchiver.config.logger calls.
  def self.logger
    config.logger
  end

  def self.listener
    config.listener
  end

  # Error raised when authentication is required but credentials are missing
  class AuthenticationError < StandardError; end
end
