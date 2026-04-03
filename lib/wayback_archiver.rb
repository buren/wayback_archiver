require 'wayback_archiver/rate_limiter'
require 'wayback_archiver/retry'
require 'wayback_archiver/thread_pool'
require 'wayback_archiver/null_logger'
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
  def self.archive(source, legacy_strategy = nil, strategy: :auto, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, **options, &block)
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
  def self.auto(source, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, hosts: [], skip_urls: nil, **options, &block)
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
        WaybackArchiver.logger.info "Source URL is an RSS/Atom feed with #{feed_urls.length} entries"
        WaybackArchiver.logger.info "Strategy resolved: feed (#{feed_urls.length} URLs)"
        return urls(feed_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
      end
    end

    # Step 2: Try sitemap autodiscovery
    sitemap_urls = Sitemapper.autodiscover(source)
    if sitemap_urls.any?
      WaybackArchiver.logger.info "Strategy resolved: sitemap (#{sitemap_urls.length} URLs)"
      return urls(sitemap_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    end

    # Step 3: Try feed autodiscovery (HTML link tags + common feed paths)
    feed_urls = FeedParser.autodiscover(source, html: source_body)
    if feed_urls.any?
      WaybackArchiver.logger.info "Found RSS/Atom feed with #{feed_urls.length} entries"
      WaybackArchiver.logger.info "Strategy resolved: feed (#{feed_urls.length} URLs)"
      return urls(feed_urls, concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
    end

    # Step 4: Crawl
    WaybackArchiver.logger.info "Strategy resolved: crawl"
    crawl(source, concurrency: concurrency, limit: limit, hosts: hosts, skip_urls: skip_urls, **options, &block)
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
  def self.crawl(url, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Crawling #{url}"
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
  def self.sitemap(url, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Fetching Sitemap"
    Archive.post(URLCollector.sitemap(url), concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
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
  def self.rss(url, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, **options, &block)
    WaybackArchiver.logger.info "Fetching RSS/Atom feed"
    Archive.post(URLCollector.feed(url), concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
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
  def self.urls(urls, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, skip_urls: nil, **options, &block)
    Archive.post(Array(urls), concurrency: concurrency, limit: limit, skip_urls: skip_urls, **options, &block)
  end

  # Discover URLs using the specified strategy without archiving them.
  # @return [Array<String>] discovered URLs
  # @param [String/Array<String>] source for URL(s).
  # @param [String/Symbol] strategy for URL discovery.
  # @param [Array<String, Regexp>] hosts to crawl (crawl strategy only).
  # @param [Integer] limit max number of URLs.
  def self.discover_urls(source, strategy: 'auto', hosts: [], limit: max_limit)
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
  def self.check(urls, concurrency: WaybackArchiver.concurrency, &block)
    CDX.check_urls(urls, concurrency: concurrency, &block)
  end

  # Auto-discover URLs without archiving (mirrors the auto strategy logic).
  def self.discover_urls_auto(source, hosts: [], limit: max_limit)
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

  # Configure WaybackArchiver with a block.
  # @yield [WaybackArchiver] the module itself for configuration.
  # @return [WaybackArchiver]
  # @example
  #   WaybackArchiver.configure do |config|
  #     config.access_key = 'your-access-key'
  #     config.secret_key = 'your-secret-key'
  #     config.concurrency = 8
  #   end
  def self.configure
    yield self
    self
  end

  # Error raised when authentication is required but credentials are missing
  class AuthenticationError < StandardError; end

  # Sets the Internet Archive S3 access key
  # @return [String, nil] the configured access key
  # @param [String, nil] key the access key
  def self.access_key=(key)
    @access_key = key
    WaybackMachine.reset_rate_limiter!
  end

  # Returns the configured access key, falling back to environment variables
  # @return [String, nil] the access key
  def self.access_key
    @access_key || ENV['WAYBACK_ACCESS_KEY'] || ENV['IA_S3_ACCESS_KEY']
  end

  # Sets the Internet Archive S3 secret key
  # @return [String, nil] the configured secret key
  # @param [String, nil] key the secret key
  def self.secret_key=(key)
    @secret_key = key
    WaybackMachine.reset_rate_limiter!
  end

  # Returns the configured secret key, falling back to environment variables
  # @return [String, nil] the secret key
  def self.secret_key
    @secret_key || ENV['WAYBACK_SECRET_KEY'] || ENV['IA_S3_SECRET_KEY']
  end

  # Returns whether both access_key and secret_key are configured
  # @return [Boolean]
  def self.credentials?
    !access_key.nil? && !secret_key.nil?
  end

  # Set logger
  # @return [Object] the set logger
  # @param [Object] logger an object than response to quacks like a Logger
  # @example set a logger that prints to standard out (STDOUT)
  #    WaybackArchiver.logger = Logger.new(STDOUT)
  def self.logger=(logger)
    @logger = logger
  end

  # Returns the current logger
  # @return [Object] the current logger instance
  def self.logger
    @logger ||= NullLogger.new
  end

  # Resets the logger to the default
  # @return [NullLogger] a new instance of NullLogger
  def self.default_logger!
    @logger = NullLogger.new
  end

  # Sets the user agent
  # @return [String] the configured user agent
  # @param [String] user_agent the desired user agent
  def self.user_agent=(user_agent)
    @user_agent = user_agent
  end

  # Returns the configured user agent
  # @return [String] the configured or the default user agent
  def self.user_agent
    @user_agent ||= USER_AGENT
  end

  # Sets the default respect_robots_txt
  # @return [Boolean] the desired default for respect_robots_txt
  # @param [Boolean] respect_robots_txt the desired default
  def self.respect_robots_txt=(respect_robots_txt)
    @respect_robots_txt = respect_robots_txt
  end

  # Returns the default respect_robots_txt
  # @return [Boolean] the configured or the default respect_robots_txt
  def self.respect_robots_txt
    @respect_robots_txt ||= DEFAULT_RESPECT_ROBOTS_TXT
  end

  # Sets the default concurrency
  # @return [Integer] the desired default concurrency
  # @param [Integer] concurrency the desired default concurrency
  def self.concurrency=(concurrency)
    @concurrency = concurrency
  end

  # Returns the default concurrency
  # @return [Integer] the configured or the default concurrency
  def self.concurrency
    @concurrency ||= DEFAULT_CONCURRENCY
  end

  # Sets the default max_limit
  # @return [Integer] the desired default max_limit
  # @param [Integer] max_limit the desired default max_limit
  def self.max_limit=(max_limit)
    @max_limit = max_limit
  end

  # Returns the default max_limit
  # @return [Integer] the configured or the default max_limit
  def self.max_limit
    @max_limit ||= DEFAULT_MAX_LIMIT
  end

  # Sets the adapter
  # @return [Object, #call>] the configured adapter
  # @param [Object, #call>] the adapter
  def self.adapter=(adapter)
    unless adapter.respond_to?(:call)
      raise(ArgumentError, 'adapter must implement #call')
    end

    @adapter = adapter
  end

  # Returns the configured adapter
  # @return [Integer] the configured or the default adapter
  def self.adapter
    @adapter ||= WaybackMachine
  end
end
