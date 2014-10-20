# WaybackArchiver
[![Code Climate](https://codeclimate.com/github/buren/wayback_archiver.png)](https://codeclimate.com/github/buren/wayback_archiver) [![Dependency Status](https://gemnasium.com/buren/wayback_archiver.svg)](https://gemnasium.com/buren/wayback_archiver)
 [![Gem Version](https://badge.fury.io/rb/wayback_archiver.svg)](http://badge.fury.io/rb/wayback_archiver)

Send URLs to [Wayback Machine](https://archive.org/web/) from [/sitemap.xml](http://www.sitemaps.org), single URL or file with URLs. You can also ask `WaybackArchiver` to crawl your website for URLs.


## Installation
Install the gem:
```bash
gem install wayback_archiver
```

## Usage

Command line usage:
```bash
wayback_archiver example.com               # Send each URL defined in example.com/sitemap.xml
wayback_archiver example.com crawl         # Crawl all found links on page that has with example.com domain
wayback_archiver example.com/some/path url # Only send example.com/some/path
wayback_archiver /path/to/file file        # With an URL on each line
```

Ruby usage:
```ruby
require 'wayback_archiver'
WaybackArchiver.archive('example.com', :sitemap) # Send each URL defined in example.com/sitemap.xml
WaybackArchiver.archive('example.com', :crawl)   # Crawl all found links on page that has with example.com domain
WaybackArchiver.archive('example.com', :url)     # Only send http://example.com/some/path
WaybackArchiver.archive('/path/to/file', :file)  # With an URL on each line
```

View archive: https://web.archive.org/web/*/http://example.com

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

---------

* Don't know what the Wayback Machine is? [Wayback Machine](https://archive.org/web/)  
* Don't know what a sitemap is? [http://sitemaps.org](http://www.sitemaps.org)
