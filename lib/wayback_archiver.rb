require 'wayback_archiver/thread_pool'
require 'wayback_archiver/null_logger'
require 'wayback_archiver/version'
require 'wayback_archiver/url_collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/sitemapper'

# WaybackArchiver, send URLs to Wayback Machine. By crawling, sitemap or by passing a list of URLs.
module WaybackArchiver
  # Link to gem on rubygems.org, part of the sent User-Agent
  INFO_LINK  = 'https://rubygems.org/gems/wayback_archiver'.freeze
  # WaybackArchiver User-Agent
  USER_AGENT = "WaybackArchiver/#{WaybackArchiver::VERSION} (+#{INFO_LINK})".freeze

  # Default concurrency for archiving URLs
  DEFAULT_CONCURRENCY = 1

  # Maxmium number of links posted (-1 is no limit)
  DEFAULT_MAX_LIMIT = -1

  # Send URLs to Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String/Array<String>] source for URL(s).
  # @param [String/Symbol] strategy of source. Supported strategies: crawl, sitemap, url, urls, auto.
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
  def self.archive(source, legacy_strategy = nil, strategy: :auto, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, &block)
    strategy = legacy_strategy || strategy

    case strategy.to_s
    when 'crawl'   then crawl(source, concurrency: concurrency, limit: limit, hosts: hosts, &block)
    when 'auto'    then auto(source, concurrency: concurrency, limit: limit, &block)
    when 'sitemap' then sitemap(source, concurrency: concurrency, limit: limit, &block)
    when 'urls'    then urls(source, concurrency: concurrency, limit: limit, &block)
    when 'url'     then urls(source, concurrency: concurrency, limit: limit, &block)
    else
      raise ArgumentError, "Unknown strategy: '#{strategy}'. Allowed strategies: sitemap, urls, url, crawl"
    end
  end

  # Look for Sitemap(s) and if nothing is found fallback to crawling.
  # Then send found URLs to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] source (must be a valid URL).
  # @param concurrency [Integer]
  # @example Auto archive example.com
  #    WaybackArchiver.auto('example.com') # Default concurrency is 5
  # @example Auto archive example.com with low concurrency
  #    WaybackArchiver.auto('example.com', concurrency: 1)
  # @example Auto archive example.com and archive max 100 URLs
  #    WaybackArchiver.auto('example.com', limit: 100)
  # @see http://www.sitemaps.org
  def self.auto(source, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, &block)
    urls = Sitemapper.autodiscover(source)
    return urls(urls, concurrency: concurrency, &block) if urls.any?

    crawl(source, concurrency: concurrency, &block)
  end

  # Crawl site for URLs to send to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] url to start crawling from.
  # @param [Array<String, Regexp>] hosts to crawl
  # @param concurrency [Integer]
  # @example Crawl example.com and send all URLs of the same domain
  #    WaybackArchiver.crawl('example.com') # Default concurrency is 5
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
  def self.crawl(url, hosts: [], concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, &block)
    WaybackArchiver.logger.info "Crawling #{url}"
    Archive.crawl(url, hosts: hosts, concurrency: concurrency, limit: limit, &block)
  end

  # Get URLs from sitemap and send found URLs to the Wayback Machine.
  # @return [Array<ArchiveResult>] of URLs sent to the Wayback Machine.
  # @param [String] url to the sitemap.
  # @param concurrency [Integer]
  # @example Get example.com sitemap and archive all found URLs
  #    WaybackArchiver.sitemap('example.com/sitemap.xml') # Default concurrency is 5
  # @example Get example.com sitemap and archive all found URLs with low concurrency
  #    WaybackArchiver.sitemap('example.com/sitemap.xml', concurrency: 1)
  # @example Get example.com sitemap archive max 100 URLs
  #    WaybackArchiver.sitemap('example.com/sitemap.xml', limit: 100)
  # @see http://www.sitemaps.org
  def self.sitemap(url, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, &block)
    WaybackArchiver.logger.info "Fetching Sitemap"
    Archive.post(URLCollector.sitemap(url), concurrency: concurrency, limit: limit, &block)
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
  def self.urls(urls, concurrency: WaybackArchiver.concurrency, limit: WaybackArchiver.max_limit, &block)
    Archive.post(Array(urls), concurrency: concurrency, &block)
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
