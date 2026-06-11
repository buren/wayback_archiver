# Change Log

## HEAD

- **List URLs mode** — `--list-urls` discovers URLs using any strategy (crawl, sitemap, RSS, auto) and prints them one per line without archiving. Useful for auditing site contents, previewing before archiving, or piping to other tools. Supports all filter options (`--skip-patterns`, `--include-ext`, `--exclude-ext`, `--limit`). Logging is suppressed by default for clean pipe-friendly output.
- **Crawl deduplication** — pages with the same URL path and identical body content are automatically skipped during crawl, preventing infinite pagination from flooding SPN2 with duplicate submissions. Opt out with `--no-skip-duplicates` or `skip_duplicates: false`. New `on_duplicate_skipped` listener event and duplicate count in CLI summary.
- **Crawl HTTP filtering** — non-success pages (404, 500, etc.) discovered during crawl are now filtered out before archiving instead of being submitted to SPN2 and failing predictably.
- **Quieter retry logging** — intermediate retry attempts (connection errors, transient SPN2 errors, poll failures) now log at debug level instead of WARN. Only final failures (retry limit exceeded) log at ERROR.
- **Increased retry limit** — per-URL retry cap for transient errors increased from 3 to 5, improving tolerance for intermittent SPN2 gateway timeouts and connection refused errors.
- **Skip patterns** — `--skip-patterns=PATTERN` accepts comma-separated regex patterns to exclude matching URLs from archiving. Works for all strategies. Ruby API: `skip_patterns: [/pattern/]`.

## v2.0.0

**Breaking changes:**

- **Authentication required** — the Wayback Machine SPN2 API no longer allows anonymous access. You must configure Internet Archive S3 API keys (`WAYBACK_ACCESS_KEY`/`WAYBACK_SECRET_KEY`) before archiving. Get your keys at [archive.org/account/s3.php](https://archive.org/account/s3.php). Read-only operations like `--check` (CDX API) still work without credentials.
- Switched from SPN1 to **SPN2 API** — captures are now submitted via POST and polled for completion
- `archive`, `crawl`, `sitemap`, `urls` now return **all results** (including failures), not just successes. Use `result.success?` to filter.
- `ArchiveResult#success?` is now `false` for `submitted?` (queued but unconfirmed) results in addition to errors. `cached?` and `skipped?` results count as successes (the URL is archived / was intentionally not re-archived) — use the `cached?`/`skipped?` predicates if you need to distinguish them.
- **`ArchiveResult` pruned** — the vestigial v1 readers `code` (always `'200'`), `request_url` (never set), and `archived_url` (alias of `uri`) are removed. Use `uri` for the archived URL and `wayback_url` for the snapshot link.
- **Positional strategy argument removed** — `WaybackArchiver.archive('example.com', :crawl)` now raises `ArgumentError`. Use the keyword form: `WaybackArchiver.archive('example.com', strategy: :crawl)`.
- **Module-level setters removed** — settings now live on `WaybackArchiver.config`. The following no longer exist and raise `NoMethodError`: `WaybackArchiver.logger=`, `.default_logger!`, `.user_agent`/`.user_agent=`, `.concurrency=`, `.max_limit=`, `.respect_robots_txt`/`.respect_robots_txt=`, and `.adapter`/`.adapter=` (the swappable adapter extension point is gone; archiving always uses SPN2). See the migration table below.
- Default concurrency changed from 1 to 4
- Ruby >= 3.1 required
- SSL certificate verification enabled by default
- Removed deprecated development dependencies (`coveralls`, `redcarpet`, `byebug`)

**Migration from v1:**

| v1 (removed) | v2 |
| --- | --- |
| `WaybackArchiver.logger = l` | `WaybackArchiver.config.logger = l` |
| `WaybackArchiver.concurrency = n` | `WaybackArchiver.config.concurrency = n` |
| `WaybackArchiver.max_limit = n` | `WaybackArchiver.config.max_limit = n` |
| `WaybackArchiver.user_agent = s` | `WaybackArchiver.config.user_agent = s` |
| `WaybackArchiver.respect_robots_txt = b` | `WaybackArchiver.config.respect_robots_txt = b` |
| `WaybackArchiver.default_logger!` | (removed — logger defaults to `NullLogger`) |
| `WaybackArchiver.adapter = a` | (removed — SPN2 is the only backend) |

The `configure` block still works and is the recommended entry point:

```ruby
WaybackArchiver.configure do |config|
  config.access_key = 'your-access-key'
  config.secret_key = 'your-secret-key'
  config.concurrency = 8
end
```

CLI exit codes: `0` success, `1` finished with one or more failed URLs, `2` invalid arguments, `3` credentials missing, `130` interrupted (Ctrl+C).

**New features:**

- **Authentication** — configure Internet Archive S3 API keys via `access_key`/`secret_key` (programmatic, env vars, or CLI flags)
- **SPN2 capture options** — `capture_all`, `capture_outlinks`, `capture_screenshot`, `force_get`, `skip_first_archive`, `if_not_archived_within`, `js_behavior_timeout`, `use_user_agent`, `delay_wb_availability`
- **Screenshot download** — save full-page PNG screenshots locally with `screenshot_dir:` option (requires auth)
- **Rich results** — `ArchiveResult` now includes `job_id`, `timestamp`, `duration_sec`, `resources`, `outlinks`, `screenshot_url`, `original_url`, `status_ext`, `wayback_url`
- **Cached capture detection** — when `if_not_archived_within` matches a recent snapshot, SPN2 returns immediately; these are tagged with `status_ext: 'cached'` and reported separately in the CLI summary
- **Retry with backoff** — transient SPN2 errors (rate limits, service unavailable) are retried automatically with exponential backoff
- **Expanded error classification** — 38 SPN2 error codes mapped to `:transient`, `:daily_limit`, and `:permanent` categories for smarter retry decisions
- **Proactive rate limiter** — token bucket rate limiting to stay within SPN2 limits proactively
- **Streaming crawl** — crawl strategy streams discovered URLs to SPN2 as they are found, instead of waiting for the crawl to finish. New listener events `on_url_discovered` and `on_crawl_complete` track progress.
- **Smart crawl filtering** — crawler only yields archivable content types (HTML, PDF, XML, RSS, JSON, plain text, Word docs), automatically skipping images, CSS, JS, and fonts. SPN2 captures embedded assets as part of page snapshots.
- **Batch status polling** — efficient bulk archiving via `POST /save/status` with multiple job IDs
- **CDX API integration** — `--check` queries the Wayback Machine CDX API to see if URLs are already archived; `--skip-archived[=TIMEDELTA]` skips URLs already in the archive (optionally within a time window)
- **Resumable sessions** — `--session=PATH` writes a progressive JSONL state file during archiving; `--resume=PATH` picks up where a previous run left off, skipping already-completed URLs
- **File input** — `--file=PATH` (or `-f`) reads URLs from a file (one per line, `#` comments supported, `-` for stdin)
- **RSS/Atom feed strategy** — `strategy: :rss` for archiving URLs from RSS and Atom feeds (not included in `:auto` since feeds typically contain only recent posts)
- **Report export** — `--report=results.csv` or `--report=results.json` from the CLI
- **Event listener system** — subscribe to lifecycle events (`on_resolved`, `on_batch_start`, `on_url_discovered`, `on_crawl_complete`, `on_submitted`, `on_completed`, `on_progress`, `on_waiting_for_slots`) for custom progress reporting. Subclass `NullListener`, pass a hash of procs, or use any object — unimplemented events are silently skipped.
- **Configuration class** — all settings extracted into `WaybackArchiver::Configuration`, accessed via `WaybackArchiver.config`. The `configure` block and the read-only convenience delegates `WaybackArchiver.logger`/`.listener` still work; the module-level *setters* were removed (see Breaking changes above).
- **SPN2 system/user status** — `--status` flag queries `POST /save/status/system` and `POST /save/status/user` and exits
- **URL extension filtering** — `--include-ext=pdf,doc` archives only matching URLs; `--exclude-ext=zip,png` skips matching URLs. Available via Ruby API as `include_ext:` / `exclude_ext:` parameters.
- **Outlinks availability** — `--outlinks-availability` returns last-capture timestamps for outlinks
- **TTY progress bar** — sticky two-line footer with adaptive progress bar, ETA (exponential moving average), and state indicator (Submitting/Polling/Waiting). Automatically hidden on non-TTY output.
- **Connection error retry** — transient connection errors (timeouts, refused, reset) retried with exponential backoff (up to 5 attempts)
- **Ctrl+C handling** — graceful interrupt shows summary of progress so far and a `--resume` command to continue
- **Dynamic chunk sizing** — batch submissions adapt chunk size based on `check_user_status` response and available capture slots
- **CLI improvements** — summary after archiving (`--[no-]summary`), `--quiet` mode, `--rss` flag, input validation for concurrency/limit/timeout/host patterns, startup banner showing limit/hosts/skip-archived, human-readable duration in summary (h/m/s)
- **`Request.post`** — new HTTP POST support in the request layer
- **GitHub Actions CI** — replaced Travis CI, testing Ruby 3.1–3.4
- **Examples directory** — runnable scripts for all common use cases
- **`bin/console`** — IRB console with the gem pre-loaded for local development

**Bug fixes / internal:**

- Fixed CLI typo: `Verboes` → `Verbose`
- Removed duplicate `-h` flag in CLI
- Fixed `:auto` strategy not passing `limit:` to all code paths
- Fixed `:auto` strategy not passing `hosts:` to crawl
- Fixed crawler not following redirects to different hosts
- Fixed `Sitemapper.autodiscover` crash on URLs without scheme
- Fixed `poll_statuses` Array response causing lost results and bloated pending list
- Re-queue transient poll errors for fresh submit in batch mode
- Route log output through progress renderer to prevent footer corruption
- Added `logger`, `rss`, `csv` as explicit gem dependencies (removed from Ruby stdlib)
- Replaced vendored `robots.rb` with `webrobots` gem
- Refactored CLI into focused classes (`CLI`, `CLIListener`, `CLI::OptionParser`, `CLI::ProgressRenderer`, `CLI::Summary`)

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
