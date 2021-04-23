# Change Log

## HEAD

## v1.4.0

* Don't respect robots.txt file by default, [PR#41](https://github.com/buren/wayback_archiver/pull/41)
* Add `WaybackArchiver::respect_robots_txt=` configuration option, to control whether to respect robots.txt file or not
* Update `spidr` gem, resolves [issue#25](https://github.com/buren/wayback_archiver/issues/25)
* Set default concurrency to `1` due to harsher rate limiting on Wayback Machine
* Support for crawling multiple hosts, for example www.example.com, example.com and app.example.com [PR#27](https://github.com/buren/wayback_archiver/pull/27)

## v1.3.0

* Archive every page found, not only HTML pages - [#24](https://github.com/buren/wayback_archiver/pull/24) thanks [@chlorophyll-zz](https://github.com/chlorophyll-zz).

## v1.2.1

* Track what urls have been visited in sitemapper and don't visit them twice
* Protect sitemap index duplicates

## v1.2.0

 Is history...
