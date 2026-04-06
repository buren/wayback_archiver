# CLAUDE.md

## Quick reference

```bash
bundle exec rake        # run tests (default task)
bundle exec rspec       # run tests directly
bundle exec rspec spec/wayback_archiver/archive_spec.rb  # run one file
```

## Architecture

Ruby gem wrapping the Internet Archive's SPN2 API. CLI entry point (`bin/wayback_archiver`) delegates to `CLI.run` which coordinates option parsing, session management, archiving, and summary output.

**Strategy dispatch**: `WaybackArchiver.archive(url, strategy:)` routes to crawl/sitemap/rss/urls/auto. Auto cascades: feed → sitemap → feed autodiscovery → crawl.

**Configuration**: `WaybackArchiver.config` returns a `Configuration` instance holding all settings (concurrency, credentials, etc.). `WaybackArchiver.logger` and `.listener` are convenience delegates. All other config goes through `config`.

**Options flow**: CLI → `options` hash → `WaybackArchiver.archive(**options)` → `Archive.post`/`Archive.crawl` → `Archive.batch_post` (chunked submit + poll loop). SPN2-specific options pass through via `**options` to `WaybackMachine`. Filtering options (`skip_urls`, `include_ext`, `exclude_ext`) are consumed by `Archive` before reaching `WaybackMachine`.

**Event system**: `WaybackArchiver.listener` dispatches lifecycle events (`on_resolved`, `on_batch_start`, `on_submitted`, `on_completed`, `on_progress`, `on_waiting_for_slots`) to listeners. CLI uses `CLIListener` + `ProgressRenderer` for TTY progress bars.

**Error handling**: `ErrorCodes` classifies 38 SPN2 `status_ext` codes into `:transient`, `:daily_limit`, `:permanent`. Transient errors trigger automatic retry with backoff (up to 3 attempts).

**Concurrency**: `concurrent-ruby` thread pools. `ThreadPool.build(1)` returns `ImmediateExecutor` (synchronous); `build(n)` returns `FixedThreadPool`.

**Rate limiter**: Sliding window, sleeps inside mutex. This is intentional — holds the lock while sleeping to enforce cross-thread rate limiting.

## Testing conventions

- WebMock disables all real HTTP — no network in tests
- `spec/spec_helper.rb` resets concurrency to 1, disables rate limiting, clears credentials
- Use `allow(described_class).to receive(:post_url)` to stub archiving in Archive specs
- Crawl tests use `and_yield` on `URLCollector.crawl` to simulate discovered URLs

## SPN2 API reference

The authoritative API docs are in `docs/spn2-api.md` (converted from the official Google Doc). Covers capture requests, status polling, error codes, rate limits, and all supported parameters. Consult this when modifying `WaybackMachine` or adding SPN2 features.

## Key files

- `lib/wayback_archiver.rb` — strategy dispatch, `discover_urls`, convenience delegates
- `lib/wayback_archiver/configuration.rb` — `Configuration` class (all settings)
- `lib/wayback_archiver/archive.rb` — `post`, `crawl`, `batch_post`, URL filtering
- `lib/wayback_archiver/adapters/wayback_machine.rb` — SPN2 submit/poll, rate limiting
- `lib/wayback_archiver/error_codes.rb` — SPN2 `status_ext` → category mapping (transient/daily_limit/permanent)
- `lib/wayback_archiver/archive_result.rb` — `ArchiveResult` value object with status helpers
- `lib/wayback_archiver/cdx.rb` — CDX API client for `--check` / `--skip-archived`
- `lib/wayback_archiver/session_file.rb` — append-only JSONL session for resume support
- `lib/wayback_archiver/url_filter.rb` — `include_ext` / `exclude_ext` filtering
- `lib/wayback_archiver/listener.rb` — `NullListener` base class and `ListenerProxy`; subclass to receive events
- `lib/wayback_archiver/report.rb` — CSV/JSON report export
- `lib/wayback_archiver/screenshot.rb` — download screenshots from archive.org
- `lib/wayback_archiver/cli.rb` — `CLIListener` (event listener for CLI output) and `CLI` class (main runner: parse → discover → archive → summarize)
- `lib/wayback_archiver/cli/option_parser.rb` — `CLI::OptionParser` definitions for all flags
- `lib/wayback_archiver/cli/progress_renderer.rb` — TTY sticky footer with progress bar and ETA
- `lib/wayback_archiver/cli/summary.rb` — end-of-run summary and failure breakdown
- `bin/wayback_archiver` — thin CLI entry point, delegates to `CLI.run`
