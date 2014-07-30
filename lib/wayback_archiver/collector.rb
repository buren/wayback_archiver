module WaybackArchiver
  class Collector

    class << self

      def urls_from_sitemap(url)
        urls     = Array.new
        xml_data = Request.get_response(url).body
        document = REXML::Document.new(xml_data)

        document.elements.each('urlset/url/loc') { |element| urls << element.text }
        urls
      end

      def urls_from_file(path)
        raise ArgumentError, "No such file: #{path}" unless File.exist?(path)
        urls = Array.new
        text = File.open(path).read
        text.gsub!(/\r\n?/, "\n") # Normalize line endings
        text.each_line { |line| urls << line.gsub(/\n/, '').strip }
        urls.reject(&:empty?)
      end

    end

  end
end
