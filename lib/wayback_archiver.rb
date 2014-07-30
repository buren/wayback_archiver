require 'uri'
require 'net/http'
require 'rexml/document'

require 'wayback_archiver/collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/request'

module WaybackArchiver
  BASE_URL = 'https://web.archive.org/save/'

  def self.archive(source, from = :sitemap)
    urls = case from
    when :sitemap, 'sitemap'
      Collector.urls_from_sitemap("#{source}/sitemap.xml")
    when :url, 'url'
      Array(source)
    when :file, 'file'
      Collector.urls_from_file(source)
    else
      raise ArgumentError, "Unknown type: '#{from}'. Allowed types: sitemal, url, file"
    end
    Archive.post(urls)
  end

end
