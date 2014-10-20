require 'uri'
require 'net/http'
require 'rexml/document'

require 'wayback_archiver/collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/request'
require 'wayback_archiver/crawler'

module WaybackArchiver
  BASE_URL = 'https://web.archive.org/save/'

  def self.archive(source, from = :sitemap)
    urls = case from.to_s
    when 'sitemap'
      Collector.urls_from_sitemap("#{source}/sitemap.xml")
    when 'url'
      Array(source)
    when 'file'
      Collector.urls_from_file(source)
    when 'crawler'
      Crawler.collect_urls(source)
    else
      raise ArgumentError, "Unknown type: '#{from}'. Allowed types: sitemal, url, file"
    end
    Archive.post(urls)
  end

end
