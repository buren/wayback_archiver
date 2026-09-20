require 'digest'
require 'spidr'

require 'wayback_archiver/sitemapper'
require 'wayback_archiver/feed_parser'
require 'wayback_archiver/request'

module WaybackArchiver
  # Retrive URLs from different sources
  # @api private
  class URLCollector
    # Thrown to unwind a crawl early. A crawl block that has collected
    # everything it needs throws this instead of letting Spidr keep walking
    # the site; {.crawl} catches it and returns normally.
    HALT = :wayback_archiver_halt_crawl

    # Retrieve URLs from Sitemap.
    # @return [Array<String>] of URLs defined in Sitemap.
    # @param [String] url domain to retrieve Sitemap from.
    # @example Get URLs defined in Sitemap for google.com
    #    URLCollector.sitemap('https://google.com/sitemap.xml')
    def self.sitemap(url)
      Sitemapper.urls(url: Request.build_uri(url))
    end

    # Retrieve URLs from an RSS or Atom feed.
    # @return [Array<String>] of URLs found in the feed.
    # @param [String] url to the RSS or Atom feed.
    # @example Get URLs from an RSS feed
    #    URLCollector.feed('https://example.com/feed.xml')
    def self.feed(url)
      FeedParser.urls(url: Request.build_uri(url).to_s)
    end

    # Retrieve URLs by crawling.
    # @return [Array<String>] of URLs defined found during crawl.
    # @param [String] url domain to crawl URLs from.
    # @param [Array<String, Regexp>] hosts to crawl.
    # @param limit [Integer] max number of archivable URLs to yield (-1 for
    #   unlimited). Counts yielded URLs, not pages visited.
    # @example Crawl URLs defined on example.com
    #    URLCollector.crawl('http://example.com')
    # @example Crawl example.com and stop after 100 archivable URLs
    #    URLCollector.crawl('http://example.com', limit: 100)
    # @example Crawl example.com with no upper limit
    #    URLCollector.crawl('http://example.com', limit: -1)
    # @example Crawl multiple hosts
    #    URLCollector.crawl(
    #      'http://example.com',
    #      hosts: [
    #        'example.com',
    #        /host[\d]+\.example\.com/
    #      ]
    #    )
    #
    # Extension filtering is deliberately absent here. Spidr's exts/ignore_exts
    # gate *traversal*, not output: constraining them to, say, "pdf" makes
    # Spidr refuse to visit the HTML pages that link to the PDFs, and the crawl
    # finds nothing. Callers filter the yielded URLs with {URLFilter} instead.
    #
    # The limit is enforced here rather than through Spidr's own :limit, which
    # counts pages visited — a link to a .zip or a dead link burns a slot
    # without producing an archivable URL, so --limit N delivered fewer than N.
    def self.crawl(url, hosts: [], limit: WaybackArchiver.config.max_limit, skip_duplicates: true, capture_all: false)
      urls = []
      seen_pages = {} # path (without query) => MD5 digest of body
      start_at_url = resolve_start_url(Request.build_uri(url).to_s)
      options = {
        robots: WaybackArchiver.config.respect_robots_txt,
        hosts: hosts,
        user_agent: WaybackArchiver.config.user_agent
      }

      catch(HALT) do
        Spidr.site(start_at_url, **options) do |spider|
          spider.every_page do |page|
            # Non-success pages would fail predictably at SPN2 — except under
            # capture_all, whose purpose is archiving 4xx/5xx error pages.
            next unless page.ok? || (capture_all && page.code.to_i >= 400)
            next unless archivable_page?(page)

            if skip_duplicates
              path = page.url.path
              digest = Digest::MD5.hexdigest(page.body.to_s)
              if seen_pages[path] == digest
                WaybackArchiver.logger.debug "Skipping duplicate content: #{page.url}"
                WaybackArchiver.listener.on_duplicate_skipped(url: page.url.to_s)
                next
              end
              seen_pages[path] ||= digest
            end

            page_url = page.url.to_s
            urls << page_url
            WaybackArchiver.logger.debug "Found: #{page_url}"
            yield(page_url) if block_given?
            throw HALT if limit != -1 && urls.length >= limit
          end
        end
      end
      urls
    end

    # Content types worth archiving. Spidr visits all linked resources
    # (images, CSS, JS, fonts) to discover further links, but only these
    # types are yielded as archive targets. Assets embedded in a page are
    # captured automatically by SPN2 as part of the page snapshot.
    #
    # Uses Spidr::Page content-type methods:
    # https://github.com/postmodern/spidr/blob/master/lib/spidr/page/content_types.rb
    def self.archivable_page?(page)
      page.html? || page.pdf? || page.plain_text? ||
        page.rss? || page.atom? || page.xml? ||
        page.json? || page.ms_word?
    end
    private_class_method :archivable_page?

    # Resolve a start URL through redirects so Spidr sees the final host.
    # e.g. http://abclabs.se -> https://www.abclabs.se
    def self.resolve_start_url(url)
      response = Request.get(url, follow_redirects: true, raise_on_http_error: false)
      response.uri && !response.uri.empty? ? response.uri : url
    rescue Request::Error
      url
    end
    private_class_method :resolve_start_url
  end
end
