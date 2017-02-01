require 'spidr'
require 'robots'

module WaybackArchiver
  class Crawler
    IGNORE_EXTENSIONS = Set.new(%w(
      png jpg jpeg gif
      js css
      zip zipx gz tar rar iso bz2 z Z 7z s7z dmg lzma tbz2 tlz zz
      map
    )).freeze

    def self.crawl_site(site_url)
      urls = []
      Spidr.site(site_url, robots: true) do |spider|
        spider.every_url do |url|
          next if ignore?(url)

          urls << url
          yield(url) if block_given?
        end
      end
      urls
    end

    def self.file_extension(url)
      url.path.split('.').last
    end

    def self.ignore?(url)
      IGNORE_EXTENSIONS.include?(file_extension(url))
    end
  end
end
