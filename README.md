# WaybackArchiver

Post URLs to [Wayback Machine](https://archive.org/web/) (Internet Archive), using a crawler, from [Sitemap(s)](http://www.sitemaps.org), or a list of URLs.

> The Wayback Machine is a digital archive of the World Wide Web [...]
> The service enables users to see archived versions of web pages across time ...  
> \- [Wikipedia](https://en.wikipedia.org/wiki/Wayback_Machine)

[![Build Status](https://travis-ci.org/buren/wayback_archiver.svg?branch=master)](https://travis-ci.org/buren/wayback_archiver) [![Code Climate](https://codeclimate.com/github/buren/wayback_archiver.png)](https://codeclimate.com/github/buren/wayback_archiver) [![Docs badge](https://inch-ci.org/github/buren/wayback_archiver.svg?branch=master)](http://www.rubydoc.info/github/buren/wayback_archiver/master)
 [![Dependency Status](https://gemnasium.com/buren/wayback_archiver.svg)](https://gemnasium.com/buren/wayback_archiver) [![Gem Version](https://badge.fury.io/rb/wayback_archiver.svg)](http://badge.fury.io/rb/wayback_archiver)

__Index__

* [Installation](#installation)
* [Usage](#usage)
  - [Ruby](#ruby)
  - [CLI](#cli)
* [RubyDoc](#docs)
* [Contributing](#contributing)
* [MIT License](#license)
* [References](#references)

## Installation

Install the gem:
```
$ gem install wayback_archiver
```

Or add this line to your application's Gemfile:

```ruby
gem 'wayback_archiver'
```

And then execute:

```
$ bundle
```

## Usage

* [Ruby](#ruby)
* [CLI](#cli)

__Strategies__:

* `auto` (the default) - Will try to
    1. Find Sitemap(s) defined in `/robots.txt`
    2. Then in common sitemap locations `/sitemap-index.xml`, `/sitemap.xml` etc.
    3. Fallback to crawling (using the excellent [spidr](https://github.com/postmodern/spidr/) gem)
* `sitemap` - Parse Sitemap(s), supports [index files](https://www.sitemaps.org/protocol.html#index) (and gzip)
* `urls` - Post URL(s)

## Ruby

First require the gem

```ruby
require 'wayback_archiver'
```

Configuration (the below values are the defaults)

```ruby
WaybackArchiver.concurrency = 5
WaybackArchiver.user_agent = WaybackArchiver::USER_AGENT
WaybackArchiver.logger = Logger.new(STDOUT)
WaybackArchiver.max_limit = -1 # unlimited
WaybackArchiver.adapter = WaybackArchiver::WaybackMachine # must implement #call(url)
```

For a more verbose log you can configure `WaybackArchiver` as such:

```ruby
WaybackArchiver.logger = Logger.new(STDOUT).tap do |logger|
  logger.progname = 'WaybackArchiver'
  logger.level = Logger::DEBUG
end
```

_Pro tip_: If you're using the gem in a Rails app you can set `WaybackArchiver.logger = Rails.logger`.

_Examples_:

Auto

```ruby
# auto is the default
WaybackArchiver.archive('example.com')

# or explicitly
WaybackArchiver.archive('example.com', strategy: :auto)
```

Crawl

```ruby
WaybackArchiver.archive('example.com',  strategy: :crawl)
```

Only send one single URL

```ruby
WaybackArchiver.archive('example.com', strategy: :url)
```

Send multiple URLs

```ruby
WaybackArchiver.archive(%w[example.com www.example.com], strategy: :urls)
```

Send all URL(s) found in Sitemap

```ruby
WaybackArchiver.archive('example.com/sitemap.xml', strategy: :sitemap)

# works with Sitemap index files too
WaybackArchiver.archive('example.com/sitemap-index.xml.gz', strategy: :sitemap)
```

Specify concurrency

```ruby
WaybackArchiver.archive('example.com', strategy: :auto, concurrency: 10)
```

Specify max number of URLs to be archived

```ruby
WaybackArchiver.archive('example.com', strategy: :auto, limit: 10)
```

Each archive strategy can receive a block that will be called for each URL

```ruby
WaybackArchiver.archive('example.com', strategy: :auto) do |result|
  if result.success?
    puts "Successfully archived: #{result.archived_url}"
  else
    puts "Error (HTTP #{result.code}) when archiving: #{result.archived_url}"
  end
end
```

Use your own adapter for posting found URLs

```ruby
WaybackArchiver.adapter = ->(url) { puts url } # whatever that responds to #call
```

## CLI

__Usage__:

```
wayback_archiver [<url>] [options]
```

Print full usage instructions

```
wayback_archiver --help
```

_Examples_:

Auto

```
# auto is the default
wayback_archiver example.com

# or explicitly
wayback_archiver example.com --auto
```

Crawl

```bash
wayback_archiver example.com --crawl
```

Only send one single URL

```bash
wayback_archiver example.com --url
```

Send multiple URLs

```bash
wayback_archiver example.com www.example.com --urls
```

Crawl multiple URLs

```bash
wayback_archiver example.com www.example.com --crawl
```

Send all URL(s) found in Sitemap

```bash
wayback_archiver example.com/sitemap.xml

# works with Sitemap index files too
wayback_archiver example.com/sitemap-index.xml.gz
```

Most options

```bash
wayback_archiver example.com www.example.com --auto --concurrency=10 --limit=100 --log=output.log --verbose
```

View archive: [https://web.archive.org/web/*/http://example.com](https://web.archive.org/web/*/http://example.com) (replace `http://example.com` with to your desired domain).

## Docs

You can find the docs online on [RubyDoc](http://www.rubydoc.info/github/buren/wayback_archiver/master).

This gem is documented using `yard` (run from the root of this repository).

```bash
yard # Generates documentation to doc/
```

## Contributing

Contributions, feedback and suggestions are very welcome.

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

[MIT License](LICENSE)

## References

* Don't know what the Wayback Machine (Internet Archive) is? [Wayback Machine](https://archive.org/web/)
* Don't know what a Sitemap is? [sitemaps.org](http://www.sitemaps.org)
* Don't know what robot.txt is? [www.robotstxt.org](http://www.robotstxt.org/robotstxt.html)
