require 'uri'
require 'net/http'

require 'wayback_archiver/collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/request'
require 'wayback_archiver/crawler'
require 'wayback_archiver/crawl_url'

module WaybackArchiver
  def self.archive(source, from = :crawl)
    urls = case from.to_s
    when 'sitemap' then Collector.urls_from_sitemap("#{source}/sitemap.xml")
    when 'url'     then [Request.resolve_url(source)]
    when 'file'    then Collector.urls_from_file(source)
    when 'crawl'   then Collector.urls_from_crawl(source)
    else
      raise ArgumentError, "Unknown type: '#{from}'. Allowed types: sitemap, url, file, crawl"
    end
    Archive.post(urls)
  end
end
