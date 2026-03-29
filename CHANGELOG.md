# Change Log

## HEAD

## v2.0.0

**Breaking changes:**

- Switched from SPN1 to **SPN2 API** — captures are now submitted via POST and polled for completion
- `archive`, `crawl`, `sitemap`, `urls` now return **all results** (including failures), not just successes. Use `result.success?` to filter.
- Default concurrency changed from 1 to 4
- Ruby >= 3.1 required
- SSL certificate verification enabled by default
- Removed deprecated development dependencies (`coveralls`, `redcarpet`, `byebug`)

**New features:**

- **Authentication** — configure Internet Archive S3 API keys via `access_key`/`secret_key` (programmatic, env vars, or CLI flags) for higher rate limits (12/min vs 4/min)
- **SPN2 capture options** — `capture_all`, `capture_outlinks`, `capture_screenshot`, `force_get`, `skip_first_archive`, `if_not_archived_within`, `js_behavior_timeout`, `use_user_agent`, `delay_wb_availability`
- **Screenshot download** — save full-page PNG screenshots locally with `screenshot_dir:` option (requires auth)
- **Rich results** — `ArchiveResult` now includes `job_id`, `timestamp`, `duration_sec`, `resources`, `outlinks`, `screenshot_url`, `original_url`, `status_ext`, `wayback_url`
- **Retry with backoff** — transient SPN2 errors (rate limits, service unavailable) are retried automatically with exponential backoff
- **Proactive rate limiter** — token bucket rate limiting to stay within SPN2 limits proactively
- **Batch status polling** — efficient bulk archiving via `POST /save/status` with multiple job IDs
- **RSS/Atom feed strategy** — new `strategy: :rss` for archiving URLs from RSS and Atom feeds
- **Feed autodiscovery in `:auto`** — detects RSS/Atom feeds via HTML `<link>` tags and common feed paths before falling back to crawling (see [Auto discovery](README.md#auto-discovery))
- **Report export** — `--report=results.csv` or `--report=results.json` from the CLI
- **CLI improvements** — summary after archiving (`--[no-]summary`), `--quiet` mode, `--rss` flag
- **`Request.post`** — new HTTP POST support in the request layer
- **GitHub Actions CI** — replaced Travis CI, testing Ruby 3.1-3.4
- **Examples directory** — runnable scripts for all common use cases

**Bug fixes:**

- Fixed CLI typo: `Verboes` → `Verbose`
- Removed duplicate `-h` flag in CLI
- Fixed `:auto` strategy not passing `limit:` to all code paths
- Added `logger`, `rss`, `csv` as explicit gem dependencies (removed from Ruby stdlib)

## v1.5.0

- Strip URLs found in Sitemaps
- Inline `robots` dependency, closes [#51](https://github.com/buren/wayback_archiver/issues/51)
- Update Sitemap XML parsing to work better with newer versions of REXML
- Fix issue calling `Spidr` with option hash (i.e use double spat operator)

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
