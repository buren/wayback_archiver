module WaybackArchiver
  class Collector
    class << self
      def urls_from_sitemap(url)
        resolved = Request.resolve_url(url)
        sitemap  = Request.get_page(resolved)
        sitemap.css('loc').map { |element| element.text }
      end

      def urls_from_crawl(url)
        Crawler.collect_urls(url)
      end

      def urls_from_file(path)
        raise ArgumentError, "No such file: #{path}" unless File.exist?(path)
        urls = []
        text = File.open(path).read
        text.gsub!(/\r\n?/, "\n") # Normalize line endings
        text.each_line { |line| urls << line.gsub(/\n/, '').strip }
        urls.reject(&:empty?)
      end
    end
  end
end
