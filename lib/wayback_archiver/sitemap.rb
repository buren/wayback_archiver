require 'rexml/document'

module WaybackArchiver
  # Parse Sitemaps, https://www.sitemaps.org
  class Sitemap
    attr_reader :document

    def initialize(xml, strict: false)
      @document = REXML::Document.new(xml)
    rescue REXML::ParseException => _e
      raise if strict

      @document = REXML::Document.new('')
    end

    # Return all URLs defined in Sitemap.
    # @return [Array<String>] of URLs defined in Sitemap.
    # @example Get URLs defined in Sitemap
    #    sitemap = Sitemap.new(xml)
    #    sitemap.urls
    def urls
      @urls ||= extract_urls('url')
    end

    # Return all sitemap URLs defined in Sitemap.
    # @return [Array<String>] of Sitemap URLs defined in Sitemap.
    # @example Get Sitemap URLs defined in Sitemap
    #    sitemap = Sitemap.new(xml)
    #    sitemap.sitemaps
    def sitemaps
      @sitemaps ||= extract_urls('sitemap')
    end

    # Check if sitemap is a plain file
    # @return [Boolean] whether document is plain
    def plain_document?
      document.elements.empty?
    end

    # Return the name of the document (if there is one)
    # @return [String] the document root name
    def root_name
      return unless document.root

      document.root.name
    end

    # Returns true of Sitemap is a Sitemap index
    # @return [Boolean] of whether the Sitemap is an Sitemap index or not
    # @example Check if Sitemap is a sitemap index
    #    sitemap = Sitemap.new(xml)
    #    sitemap.sitemap_index?
    def sitemap_index?
      root_name == 'sitemapindex'
    end

    # Returns true of Sitemap lists regular URLs
    # @return [Boolean] of whether the Sitemap regular URL list
    # @example Check if Sitemap is a regular URL list
    #    sitemap = Sitemap.new(xml)
    #    sitemap.urlset?
    def urlset?
      root_name == 'urlset'
    end

    private

    # Extract URLs from Sitemap
    def extract_urls(node_name)
      return document.to_s.each_line.map(&:strip) if plain_document?

      urls = []
      document.root.elements.each("#{node_name}/loc") do |element|
        urls << element.text
      end
      urls
    end
  end
end
