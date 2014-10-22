require 'site_mapper'

require 'uri'
require 'net/http'

require 'wayback_archiver/version'
require 'wayback_archiver/collector'
require 'wayback_archiver/archive'
require 'wayback_archiver/request'

module WaybackArchiver
  def self.archive(source, from = :crawl)
    urls = case from.to_s
    when 'file'    then Archive.post(Collector.urls_from_file(source))
    when 'crawl'   then Collector.urls_from_crawl(source) { |url| Archive.post_url(url) }
    when 'sitemap' then Archive.post(Collector.urls_from_sitemap("#{source}/sitemap.xml"))
    when 'url'     then Archive.post_url(Request.resolve_url(source))
    else
      raise ArgumentError, "Unknown type: '#{from}'. Allowed types: sitemap, url, file, crawl"
    end
  end
end
