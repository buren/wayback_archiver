# WaybackArchiver
Send URLs to [Wayback Machine](https://archive.org/web/) from [/sitemap.xml](http://www.sitemaps.org), single URL or file with URLs.

## Installation
Install the gem:
```bash
gem install wayback_archiver
```

## Usage

```bash
wayback_archiver http://example.com               # Send each line defined in http://example.com/sitemap.xml
wayback_archiver http://example.com/some/path url # Only send http://example.com/some/path to Wayback Machine
wayback_archiver /path/to/some/file               # With an URL on each line
```

View domain archive: https://web.archive.org/web/*/http://example.com


## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

---------
Don't know what a sitemap is? [http://sitemaps.org](http://www.sitemaps.org)
