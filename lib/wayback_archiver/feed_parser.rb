require 'rss'
require 'uri'

require 'wayback_archiver/request'

module WaybackArchiver
  # Fetch and parse RSS/Atom feeds to extract URLs
  # @api private
  class FeedParser
    # Raised when a fetched document isn't a recognisable RSS/Atom feed.
    #
    # Mirrors Sitemapper::InvalidSitemapError: a Request::ServerError, because
    # the server answered with something unusable, so callers that already
    # rescue Request::Error handle it — the CLI maps it to exit 4, and
    # autodiscovery moves on to the next candidate.
    class InvalidFeedError < Request::ServerError; end

    # Common locations for RSS/Atom feeds
    COMMON_FEED_PATHS = %w[
      feed
      feed.xml
      rss.xml
      atom.xml
      index.xml
    ].freeze

    # Fetch a feed and return all entry/item URLs.
    # @return [Array<String>] of URLs found in the feed.
    # @param url [String] URL to the RSS or Atom feed.
    # @example Get URLs from an RSS feed
    #    FeedParser.urls(url: 'https://example.com/feed.xml')
    # @example Parse URLs from feed XML directly
    #    FeedParser.urls(xml: '<rss>...</rss>')
    def self.urls(url: nil, xml: nil)
      raise ArgumentError, 'must provide either url: or xml:' unless url || xml

      xml = Request.get(url, raise_on_http_error: true).body unless xml

      feed = RSS::Parser.parse(xml, false)

      # A feed with no entries is a legitimate empty result; input that isn't a
      # feed at all is not. Collapsing both to [] meant --rss against an HTML
      # login page exited 0 having archived nothing, looking like success.
      case feed
      when RSS::Rss
        feed.items.filter_map { |item| item.link&.strip }
      when RSS::Atom::Feed
        feed.entries.filter_map do |entry|
          link = entry.links.find { |l| l.rel.nil? || l.rel == 'alternate' }
          link&.href&.strip
        end
      else
        raise InvalidFeedError, invalid_feed_message(url, feed)
      end
    rescue RSS::Error => e
      # The parser's own message runs to several lines of position detail —
      # useful when debugging, noise for someone who pointed --rss at a page.
      WaybackArchiver.logger.debug "Feed parse failed for #{url}: #{e.class}, #{e.message}"
      raise InvalidFeedError, invalid_feed_message(url, nil)
    end

    def self.invalid_feed_message(url, feed)
      got = feed ? feed.class.name : 'an unrecognised document'
      "Response is not an RSS or Atom feed#{" (#{url})" if url}: got #{got}"
    end
    private_class_method :invalid_feed_message

    # Autodiscover RSS/Atom feeds for a site and return all entry URLs.
    # Probes HTML <link> tags and common feed paths.
    # @param url [String] base URL of the site.
    # @param html [String, nil] optional HTML body to scan for feed link tags.
    # @return [Array<String>] of URLs found in the first discovered feed.
    def self.autodiscover(url, html: nil)
      base_url = Request.build_uri(url).to_s

      html_feed_urls = feed_urls_from_html(html, base_url)
      common_feed_urls = COMMON_FEED_PATHS.map do |path|
        [base_url, path].join(base_url.end_with?('/') ? '' : '/')
      end

      candidates = (html_feed_urls + common_feed_urls).uniq

      candidates.each do |feed_url|
        WaybackArchiver.logger.info "Looking for feed at #{feed_url}"
        response = Request.get(feed_url, raise_on_http_error: false)
        next unless response.success?

        begin
          found_urls = urls(xml: response.body)
        rescue InvalidFeedError => e
          # A 200 that isn't a feed — catch-all routes answer every path with
          # the homepage. Keep probing the remaining candidates.
          WaybackArchiver.logger.debug "Not a feed at #{feed_url}: #{e.message}"
          next
        end

        if found_urls.any?
          WaybackArchiver.logger.info "Feed found at #{feed_url}"
          return found_urls
        end
      rescue Request::Error => e
        WaybackArchiver.logger.error "Error fetching feed at #{feed_url}: #{e.class}, #{e.message}"
        next
      end

      []
    end

    # Extract feed URLs from HTML <link> tags.
    # @param html [String, nil] HTML body to scan.
    # @param base_url [String] base URL for resolving relative hrefs.
    # @return [Array<String>] absolute feed URLs found.
    def self.feed_urls_from_html(html, base_url)
      return [] unless html

      html.scan(/<link[^>]+>/i).filter_map do |tag|
        next unless tag =~ /type=["']application\/(rss|atom)\+xml["']/i
        next unless tag =~ /href=["']([^"']+)["']/i

        href = Regexp.last_match(1)
        URI.join(base_url, href).to_s
      rescue URI::InvalidURIError
        nil
      end
    end
    private_class_method :feed_urls_from_html
  end
end
