# CLAUDE.md

## Quick reference

```bash
bundle exec rake        # run tests (default task)
bundle exec rspec       # run tests directly
bundle exec rspec spec/wayback_archiver/archive_spec.rb  # run one file
```

## Architecture

Ruby gem wrapping the Internet Archive's SPN2 API. CLI binary (`bin/wayback_archiver`) parses args and calls the library (`lib/wayback_archiver.rb`).

**Strategy dispatch**: `WaybackArchiver.archive(url, strategy:)` routes to crawl/sitemap/rss/urls/auto. Auto cascades: feed → sitemap → feed autodiscovery → crawl.

**Configuration**: `WaybackArchiver.config` returns a `Configuration` instance holding all settings (adapter, concurrency, credentials, etc.). `WaybackArchiver.logger` and `.listener` are convenience delegates. All other config goes through `config`.

**Adapter pattern**: `WaybackArchiver.config.adapter` (default: `WaybackMachine`). Must respond to `#call(url, **options)`. Batch-capable adapters also implement `#submit` and `#poll_statuses`.

**Options flow**: CLI → `options` hash → `WaybackArchiver.archive(**options)` → `Archive.post`/`Archive.crawl`. SPN2-specific options pass through via `**options` to the adapter. Filtering options (`skip_urls`, `include_ext`, `exclude_ext`) are consumed by `Archive` before reaching the adapter.

**Concurrency**: `concurrent-ruby` thread pools. `ThreadPool.build(1)` returns `ImmediateExecutor` (synchronous); `build(n)` returns `FixedThreadPool`.

**Rate limiter**: Sliding window, sleeps inside mutex. This is intentional — holds the lock while sleeping to enforce cross-thread rate limiting.

## Testing conventions

- WebMock disables all real HTTP — no network in tests
- `spec/spec_helper.rb` resets concurrency to 1, disables rate limiting, clears credentials
- Use `allow(described_class).to receive(:post_url)` to stub archiving in Archive specs
- Crawl tests use `and_yield` on `URLCollector.crawl` to simulate discovered URLs

## SPN2 API reference

The authoritative API docs are in `docs/spn2-api.md` (converted from the official Google Doc). Covers capture requests, status polling, error codes, rate limits, and all supported parameters. Consult this when modifying the WaybackMachine adapter or adding SPN2 features.

## Key files

- `lib/wayback_archiver.rb` — strategy dispatch, `discover_urls`, convenience delegates
- `lib/wayback_archiver/configuration.rb` — `Configuration` class (all settings)
- `lib/wayback_archiver/archive.rb` — `post`, `crawl`, `batch_post`, URL filtering
- `lib/wayback_archiver/adapters/wayback_machine.rb` — SPN2 submit/poll, rate limiting
- `bin/wayback_archiver` — CLI entry point, OptionParser, session management, summary
