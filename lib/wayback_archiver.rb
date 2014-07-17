require 'net/http'
require 'uri'
require 'rexml/document'

module WaybackArchiver
  WAYBACK_BASE_URL = 'https://web.archive.org/save/'

  def self.archive(source, from)
    from = from || :sitemap
    urls = Array.new
    case from.to_sym
    when :sitemap
      urls = WaybackArchiver.urls_from_sitemap("#{source}/sitemap.xml")
    when :url
      urls << source
    when :file
      urls = WaybackArchiver.urls_from_file(source)
    end

    urls.each_with_index do |url, index|
      puts "Archiving (#{index + 1}/#{urls.length}): #{url}"
      request_url = URI("#{WAYBACK_BASE_URL}#{url}")
      res = Net::HTTP.get_response(request_url)

      puts "#{res.code} => #{res.message}"
    end
  end

  def self.urls_from_sitemap(url)
    urls     = Array.new
    xml_data = Net::HTTP.get_response(URI.parse(url)).body
    document = REXML::Document.new(xml_data)

    document.elements.each('urlset/url/loc') { |element| urls << element.text }
    urls
  end

  def self.urls_from_file(path)
    urls = Array.new
    text = File.open(path).read
    text.gsub!(/\r\n?/, "\n") # Normalize line endings
    text.each_line { |line| urls << line.gsub(/\n/, '') }
    urls
  end

end
