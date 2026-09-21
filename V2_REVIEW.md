# v2 pre-release review

Reviewed 2026-09-21: local `v2` at `ee78910`, compared with local `master` at `b0dea0f` (v1.5.0). The diff contains 103 changed files, 15,069 insertions and 937 deletions.

Recommendation: hold the release for the critical and must-fix findings below. The feature set is coherent, but failure handling currently allows incomplete work to look successful and recovery can permanently skip unfinished captures.

This is a review, not an implementation: production code, existing tests, and existing documentation were not changed. This document is the only added repository file. Offline reproduction scripts are in `/tmp/wayback-v2-review.iPPMJQ/`.

## Verification and limits

- `bundle exec rake`: **1,016 examples, 0 failures**, seed 34967, Ruby 4.0.2 on macOS.
- A second full run with branch measurement: **1,016 examples, 0 failures**, seed 43480. **98.64% line coverage (2,099/2,128), 88.71% branch coverage (723/815)**.
- Built the 2.0.0 gem in the temporary review directory. All `lib/**/*.rb` files are packaged; only `wayback_archiver` is installed as an executable. README, changelog and license are included.
- YARD parsed successfully: 81.44% documented. Ruby examples/binaries and shell examples pass syntax checks.
- `git diff --check master...HEAD` passes.
- Read the production code, README/changelog, API reference, examples, packaging/CI, and tests around the affected contracts. Inspected installed Spidr 0.7.2 HTTP/event behavior, which differs from the project's request wrapper.
- Reproductions use WebMock or local test doubles and fake credentials. **No live captures were submitted.** Ruby 3.3/3.4 and remote CI were not executed/verified here. The online SPN2 Google Doc was inaccessible to the browser tool; API comparisons use the checked-in `docs/spn2-api.md`, and observed live-service quirks still need a controlled release smoke test.

Run the offline probes from the repository:

```sh
bundle exec ruby -Ilib /tmp/wayback-v2-review.iPPMJQ/probes.rb
bundle exec ruby /tmp/wayback-v2-review.iPPMJQ/signal_probe.rb
```

The probes print observed behavior, including failures; their process exit code is not a regression-test verdict. The signal probe terminates its own temporary child after showing that SIGINT does not exit promptly.

## Critical — security exposure

### C1. Screenshot redirects can disclose the Internet Archive API keys

Location: [request.rb:101](lib/wayback_archiver/request.rb#L101), [screenshot.rb:38](lib/wayback_archiver/screenshot.rb#L38).

`Screenshot.download` supplies `Authorization: LOW access:secret` and follows redirects. `Request.get` reapplies all headers on every hop, including a different host or an HTTPS-to-HTTP downgrade. An offline 302 from the Wayback replay URL to `https://other.example/image.jpg` delivered the fake API credentials to that other host.

This exposure is conditional on an off-origin redirect; the review does **not** establish that the live screenshot endpoint can be made to issue one or that any real credentials have leaked. Nevertheless, retaining account credentials across arbitrary redirects is a release-blocking security defect.

Action: restrict authenticated downloads to approved HTTPS origins, and strip sensitive headers when the origin changes. Also reject insecure initial download URLs when no timestamp is available. Add same-origin, cross-origin, port-change and HTTPS-downgrade redirect tests.

Probe: `screenshot_credentials_on_foreign_redirect`.

## Must fix — release blockers

### M1. Resume treats accepted jobs as successfully completed forever

Location: [session_file.rb:43](lib/wayback_archiver/session_file.rb#L43), [cli.rb:410](lib/wayback_archiver/cli.rb#L410).

`completed_urls` skips records whose `submitted` flag is true, even though `ArchiveResult#success?` correctly says those jobs are unconfirmed. The resume path never polls their stored `job_id`. Interrupt after acceptance and a subsequent capture failure is permanently invisible to future resumes.

Reproduction: a session containing one `submitted` job caused resume to archive zero URLs, make no submit or poll calls, and print “previously succeeded”.

Action: maintain separate completed and pending sets; resolve pending job IDs on resume, record terminal outcomes, and resubmit failed/expired jobs according to policy. Test interruption after acceptance followed by success, permanent failure, transient failure and expired job ID.

Probe: `resume_never_rechecks_pending_job`. Existing `session_file_spec.rb` explicitly asserts that submitted URLs belong to `completed_urls`; that test encodes the problematic policy.

### M2. Poll timeout exits successfully, deletes recovery state and leaves reports incomplete

Location: [batch_submitter.rb:95](lib/wayback_archiver/batch_submitter.rb#L95), [cli.rb:193](lib/wayback_archiver/cli.rb#L193), [cli.rb:489](lib/wayback_archiver/cli.rb#L489).

Timed-out jobs are appended directly to the returned results as `submitted`, without a final callback. The CLI only checks `errored?` to determine failure and session retention; its report callback excludes submitted notifications.

Reproduction with one perpetually pending job: **exit 0, “Succeeded: 0 / Submitted: 1”, automatic session deleted, JSON report `[]`**.

Action: define a non-success incomplete outcome, retain recovery state, report every submitted URL's final known state, and distinguish interim notifications from final unresolved results. Test a CLI submit→pending→timeout run with session and report enabled together.

Probe: `poll_timeout_cli_report_and_session` (timeout shortened locally).

### M3. Callback/report-write failures can make URLs disappear and still exit 0

Location: [batch_submitter.rb:482](lib/wayback_archiver/batch_submitter.rb#L482), [batch_submitter.rb:166](lib/wayback_archiver/batch_submitter.rb#L166), [cli.rb:372](lib/wayback_archiver/cli.rb#L372).

`record_result` invokes the user/CLI callback before adding the result to `@results`. If it raises, the worker's rescue calls the same failing callback again while trying to record an error. The second exception is swallowed by the thread pool. Counters may increment while no result is retained.

Reproduction: an `ENOSPC` from the report writer during a cached capture produced **“1 of 0 URL(s) posted”, zero results, exit 0 and deletion of the automatic session**. A public Ruby block that consistently raises likewise loses the result with concurrency 4.

Action: store authoritative results independently of observer callbacks, surface persistence failures to the CLI, and preserve recovery state. Avoid recursively invoking the same failing callback to report its own failure. Test disk-full errors and user block exceptions on submit, cached and polled paths with concurrency 1 and 4.

Probes: `persistent_callback_error_drops_result`, `report_write_failure_cli_success`.

### M4. HTTPS certificate verification is still disabled during crawling

Location: [url_collector.rb:75](lib/wayback_archiver/url_collector.rb#L75); installed dependency `spidr-0.7.2/lib/spidr/session_cache.rb:111`.

The new request wrapper verifies TLS, but Spidr uses its own connections and explicitly sets `OpenSSL::SSL::VERIFY_NONE`. Inspection at connection startup confirmed `verify_mode == 0`. Moreover, `resolve_start_url` catches the verified preflight request's SSL error and proceeds to the original URL, allowing the unverified crawl to continue.

This is inherited dependency behavior, not a newly introduced Spidr regression. It makes v2's advertised SSL-verification fix incomplete and permits untrusted network responses to influence discovered archive targets.

Action: ensure verified TLS across the actual crawler transport, using an upstream fix, controlled adapter or replacement. Add a transport-level test with an invalid certificate; a test of `Request.build_http` alone cannot protect the crawler.

Probe: `spidr_ssl_configuration`.

### M5. Real crawler connection failures are reported as successful empty/partial runs

Location: [url_collector.rb:75](lib/wayback_archiver/url_collector.rb#L75), [url_collector.rb:120](lib/wayback_archiver/url_collector.rb#L120).

Spidr catches DNS, timeout, connection and SSL exceptions internally and emits failed-URL events. This integration only subscribes to `every_page`, so the new `CrawlError` path does not see ordinary network failures. The preflight fetch also suppresses `Request::Error`.

Reproduction with the real Spidr traversal and an HTTP-level DNS failure for the seed: **exit 0, total 0, no error**. Failures later in traversal similarly leave missing URLs unreported.

Action: subscribe to `every_failed_url`, fail clearly when the seed cannot be fetched, and expose partial discovery failures while preserving successful results. Distinguish transport failures from deliberate filtering of HTTP error pages. Test real Spidr failure events rather than only mocking `URLCollector.crawl` to raise.

Probe: `real_spidr_unreachable_seed`.

### M6. Normal batch retries have no exponential backoff

Location: [batch_submitter.rb:317](lib/wayback_archiver/batch_submitter.rb#L317).

All normal CLI/archive operations use `BatchSubmitter`, whose retry buffer is immediately drained again. `Retry.with_backoff` is used by the separate single-URL API and CDX, not this path. The 12/minute limiter allows an initial burst, so it does not provide per-URL backoff.

Reproduction with the actual submit client and an enabled 12/minute limiter: six attempts against an immediate `error:service-unavailable` response completed in approximately **2 ms**, exhausting the URL's retries before the service could recover. This contradicts the documented retry behavior.

Action: schedule retries with per-URL delays/jitter while allowing unrelated work to progress. Preserve the original failure category on exhaustion. Test elapsed simulated time through the real batch orchestration, not just the standalone `Retry` helper.

Probe: `batch_transient_errors_no_backoff`.

### M7. The documented `--list-urls` pipeline outputs a bogus URL

Location: [cli.rb:328](lib/wayback_archiver/cli.rb#L328), [README.md:146](README.md#L146).

The mode suppresses logging but leaves `show_summary` enabled. Default stdout is `https://example.com/`, a blank line, then `1 URL(s) discovered`. The README's redirect-to-file command writes that summary into the input file, and a later `--file` invocation treats it as a target URL.

Action: send the summary to stderr or disable it by default in list mode. Test the exact README pipeline without adding `--no-summary` only in the test.

Probe: `list_urls_default_output`. Existing tests verify clean output only with `--no-summary` and separately expect a default summary.

### M8. `--skip-archived` changes which pages are eligible for archiving

Location: [cli.rb:451](lib/wayback_archiver/cli.rb#L451), [wayback_archiver.rb:182](lib/wayback_archiver.rb#L182).

The common discovery API accepts only strategy/hosts/limit. It does not receive `capture_all` or `skip_duplicates`. Thus `--crawl --capture-all --skip-archived` drops 4xx/5xx pages before checking them; `--no-skip-duplicates --skip-archived` still deduplicates. The same mismatch affects `--list-urls` and `--check`.

Reproductions: direct crawl with `capture_all: true` returned a 404 seed, while list mode with `--capture-all` returned zero URLs. Direct crawl with dedup disabled returned two equivalent pages, while list mode with `--no-skip-duplicates` returned only one.

Action: carry discovery-affecting options through all strategies/modes. Add cross-mode contract tests asserting the same eligible URL set before the CDX filtering step.

Probes: `read_only_discovery_ignores_capture_all`, `read_only_discovery_ignores_no_skip_duplicates`.

### M9. Ctrl+C can wait for the crawler to finish instead of stopping the run

Location: [batch_submitter.rb:107](lib/wayback_archiver/batch_submitter.rb#L107), [cli.rb:515](lib/wayback_archiver/cli.rb#L515).

Cleanup closes the queue and then joins the crawler without a cancellation mechanism or deadline. Closing the queue only stops it at its next push. A crawler blocked in network IO, or traversing pages that all fail local filters, can keep running long after the interrupt message.

A subprocess probe printed “Interrupted. Resume with:” but was still alive two seconds later because the crawler was inside a simulated 30-second blocking operation. The review terminated that child. Real crawl request timeouts are 60 seconds, and filtered traversal can take longer.

Action: add cooperative cancellation across traversal and queue operations, with bounded shutdown of outstanding network work. Extend the existing SIGINT subprocess test to an active streaming crawler; the current test uses `--urls`, so it cannot detect this.

Probe: `signal_probe.rb`.

## Should fix — correctness, recovery and reliability

### S1. Automatically generated sessions collide within the same second

Location: [session_file.rb:14](lib/wayback_archiver/session_file.rb#L14).

Paths contain only a second-resolution timestamp. Two invocations starting in the same second share an append-only file and have independent mutexes; either can read the other's successes and either successful run can delete the shared recovery file. Use an atomically created unique file, not only a timestamp. Test two simultaneous CLI instances.

Probe: `session_auto_name_collision` deterministically demonstrates identical paths; the cross-process consequences follow from append/read/delete behavior.

### S2. Generated resume commands lose mixed input and cannot reconstruct stdin

Location: [cli/summary.rb:54](lib/wayback_archiver/cli/summary.rb#L54).

If `file_path` is present, positional URLs are omitted from the resume command. A run combining `extra-url --file=urls.txt` therefore loses `extra-url` on resume. With `--file=-`, the generated command asks to read stdin again, but neither the consumed list nor the original pipeline is saved; session rows contain only attempted URLs, not all remaining input.

Persist an input manifest or reconstruct all resolved source URLs in the resume command, and test mixed input plus interrupted stdin ingestion/archiving. Probe: `resume_mixed_file_and_positional_sources`; stdin consequence is source-confirmed.

### S3. Different screenshot URLs silently overwrite the same local file

Location: [screenshot.rb:94](lib/wayback_archiver/screenshot.rb#L94).

`https://example.com/a/b` and `https://example.com/a_b` both become `example.com_a_b.jpg`. Query punctuation removal, scheme removal and truncation create further collisions, and simultaneous downloads can write the same file. Include a digest of the full URL and, if historical runs should coexist, a capture timestamp. Test collisions and concurrent writes. Probe: `screenshot_filename_collision`.

### S4. A null entry in an otherwise accepted batch response crashes the run

Location: [wayback_machine.rb:140](lib/wayback_archiver/wayback_machine.rb#L140), [batch_submitter.rb:360](lib/wayback_archiver/batch_submitter.rb#L360).

The response validator explicitly accepts nil statuses in both hash and array shapes, but array normalization dereferences `entry['job_id']` unconditionally. HTTP 200 with `[null]` raises `NoMethodError` outside the retry handler. Skip or reject null array entries consistently and test a mix of valid, pending and null records. Probe: `null_array_poll_entry`.

### S5. A bare SPN2 error status is classified as success

Location: [archive_result.rb:99](lib/wayback_archiver/archive_result.rb#L99).

`from_status(..., {'status' => 'error'})` returns `success? == true` and label `ok`: the top-level error flag is discarded and the predicate depends on optional detail fields. The status validator accepts this payload. Preserve an explicit error or a fallback message regardless of `message`/`status_ext`. The existing regression test covers missing `status_ext` only when a message is supplied. Probe: `bare_error_status`.

### S6. Invalid RSS/Atom input still looks like a successful empty feed

Location: [feed_parser.rb:31](lib/wayback_archiver/feed_parser.rb#L31).

A 200 HTML login/homepage or malformed feed becomes `[]`, and `--rss` exits 0 with zero URLs. Explicit sitemap mode now correctly rejects this situation, but feed mode does not. Distinguish a valid empty feed from unrecognized/malformed input and map the latter to a discovery error. Probe: `invalid_feed_succeeds_empty`.

### S7. Reports misclassify successful results and discard some failure reasons

Location: [archive_result.rb:56](lib/wayback_archiver/archive_result.rb#L56), [report.rb:79](lib/wayback_archiver/report.rb#L79).

Cached and skipped results have non-error `status_ext` values, yet `error_category` sends them to the unknown-error fallback and reports `transient` (also producing warnings). Poll failures store their message in `response_error`, while exports only write `error`, so a result can be `success: false` with all exported error fields null despite a useful message being available.

Only classify errored results, and serialize a consistent effective failure message. Consider adding `screenshot_path` to the report schema while it is still pre-release. Probes: `cached_and_skipped_report_error_categories`, `poll_error_message_missing_from_report`.

### S8. A configured default limit still caps crawl discovery before filtering

Location: [archive.rb:135](lib/wayback_archiver/archive.rb#L135), [url_collector.rb:64](lib/wayback_archiver/url_collector.rb#L64).

`Archive.crawl` intends to enforce the limit after filters, but omits `limit:` when calling `URLCollector.crawl`. That method defaults to `config.max_limit`, so a user who sets a finite global limit still gets early truncation. With `config.max_limit = 1`, a homepage linking to a PDF, and `include_ext: ['pdf'], limit: 1`, zero URLs were archived.

Pass an explicit unlimited discovery budget to the streaming collector and let the outer filtered count decide when to stop. Also test an explicit per-call limit larger than the global default. Probe: `configured_limit_truncates_crawl_before_filters`.

### S9. List/check limit pushdown happens before URL deduplication

Location: [cli.rb:447](lib/wayback_archiver/cli.rb#L447), [wayback_archiver.rb:201](lib/wayback_archiver.rb#L201).

For one unfiltered sitemap/feed source, discovery truncates before the CLI calls `uniq`. A sitemap containing `a, a, b` with `--list-urls --limit=2` returns only `a`. Deduplication is itself a downstream filter, contrary to the pushdown assumption. Deduplicate before truncation or restrict this optimization to collectors with a unique-output guarantee. Probe: `list_sitemap_limit_applied_before_dedup`.

### S10. Crawl deduplication remembers only the first body for each path

Location: [url_collector.rb:90](lib/wayback_archiver/url_collector.rb#L90).

The `||=` stores just the first digest. For one path with bodies A, B, B, both B pages are archived even though they are duplicates. This can waste many capture slots on query variants when the first page differs from the repeated pages. Track a set of digests per path (and decide explicitly whether the host is part of identity). Probe: `dedup_only_remembers_first_body_per_path` returned all three pages.

### S11. Session corruption handling only covers JSON syntax

Location: [session_file.rb:45](lib/wayback_archiver/session_file.rb#L45).

A line containing valid JSON such as `null` or a number raises during `data['url']`, aborting resume instead of taking the advertised corrupt-line recovery path. Validate record type and required fields before use. Reject/skip malformed records with a useful warning; test truncated JSON and valid JSON of the wrong shape. Probe: `malformed_session_valid_json_nonobject`.

## Documentation/examples — fix before publishing the affected guidance

### D1. The README's resume command cannot run as written

Location: [README.md:169](README.md#L169), [cli/option_parser.rb:355](lib/wayback_archiver/cli/option_parser.rb#L355).

`wayback_archiver --resume=session.jsonl` lacks a URL or file input and fails parsing. Current sessions do not contain a saved command/source manifest. Show the source and strategy again, or implement the self-contained resume UX. The comment “auto-saves progress, resumes on re-run” should also explain that explicit resume is required.

### D2. The streaming-results example counts queued jobs as failed completions

Location: [examples/streaming_results.rb:16](examples/streaming_results.rb#L16).

The example has no `next if result.submitted?`. Running it offline produced `[1/3] [FAIL]` through `[3/3] [FAIL]`, then successes up to `[6/3] [OK]`, followed by “3 succeeded”. Use the documented guard and a thread-safe counter. Add a runnable example smoke test. Probe: `streaming_example_labels_submissions_as_failures`.

### D3. Authentication examples contradict the required-auth API

Locations: [examples/basic.rb:6](examples/basic.rb#L6), [examples/track_outlinks.rb:34](examples/track_outlinks.rb#L34).

The basic example still says credentials are optional and only increase rate limits. The outlink-polling example configures credentials but sends none in its manual status requests. Explain env-based required credentials and authenticate the polling requests, including status/error handling and a deadline. Compare the latter with the authenticated GET example in `docs/spn2-api.md`.

### D4. Migration and host-regex guidance needs correction

Location: [README.md:131](README.md#L131), [README.md:354](README.md#L354).

The migration paragraph says `adapter` moved into `config`, but the adapter extension point was removed. The shell example `--hosts=.*.example.com` is unquoted (fails glob expansion in default zsh), leaves DNS dots unescaped and has no end anchor, so the regex also permits unintended hosts. Show a quoted, anchored pattern such as `--hosts='(^|\.)example\.com$'` and explain the matching policy. Apply the anchored form to Ruby examples as well.

### D5. Two-phase and screenshot examples lag behind the newer features

Locations: [examples/two_phase.sh:8](examples/two_phase.sh#L8), [examples/screenshots.rb:28](examples/screenshots.rb#L28), [README.md:70](README.md#L70).

The discovery example uses CDX `--check` for every URL before cutting the first CSV column with `cut`, which also corrupts CSV-quoted URLs containing commas. It should use `--list-urls --no-summary` (or the corrected default from M7). At 24 CDX requests/minute, 10,000 checks consume roughly seven hours just in rate-limit budget; this is significant for an example advertised as fast discovery. That rate agrees with the upstream client's current [CDX default](https://raw.githubusercontent.com/edgi-govdata-archiving/wayback/main/src/wayback/_client.py).

The screenshot example prints the raw screenshot field as “available at”, despite the download fix explaining that this is not the usable replay URL. The standalone advanced Ruby options example sets `screenshot_dir` without `capture_screenshot: true` or directory creation. Update the examples to match the actual workflow.

## Nitpicks / maintenance

### N1. Internal architecture guide still names removed methods

[CLAUDE.md:19](CLAUDE.md#L19) and its key-file list refer to `Archive.batch_post`; orchestration is now `BatchSubmitter#call`. This can misdirect future development and reviews. The guide also describes retry timing/attempt counts that do not match the batch implementation (M6).

### N2. Small reference facts drifted

The YARD examples in `lib/wayback_archiver.rb` still say default concurrency is 1; it is 4. `ErrorCodes::REGISTRY` contains 39 entries, while changelog/architecture comments say 38. The changelog describes system/user status calls as POST, while the implementation/reference use GET. Correct these alongside the larger example changes.

### N3. Clarify which example APIs are supported publicly

README's semver contract excludes `Report`, `Request`, and `WaybackMachine`, but the report/outlinks examples encourage callers to use them. Decide whether report export is a supported public feature of the Ruby API, or explicitly mark those examples as using unstable internals. The new public `AuthenticationError`/`CrawlError` contracts deserve mention too, because callers need them for recovery.

## Test completeness assessment

The suite is substantial and valuable: HTTP-level submit/poll integration tests, real multi-thread orchestration tests, a SIGINT subprocess test, rate-limiter tests, listener isolation, validation and packaging checks already exist. The main gap is **composed failure scenarios**, not missing tests for ordinary methods.

Highest-value additions, in order:

1. CLI submit→timeout→resume with real session/report files; pending jobs later succeed or fail; every input ends in an explicit state.
2. Disk-full/callback exceptions with real concurrency; assert retained results, nonzero exit and session survival.
3. Real Spidr DNS/TLS failures and SIGINT during streaming IO/backpressure/filtering.
4. Cross-origin authenticated redirects and verified TLS for every HTTP implementation.
5. A shared option-contract matrix across archive, list, check and skip-archived, including finite global config, duplicate sitemap entries and mixed inputs.
6. Batch retry timing with a controlled clock and the rate limiter enabled; delayed recovery must succeed without exhausting retries immediately.
7. Malformed-but-JSON API/session responses, successful cached/skipped report fields, and filename/session collisions.
8. Smoke-test the documented examples and exact README CLI pipelines against HTTP fixtures.

Line coverage alone does not establish these contracts. In particular, several tests currently assert the behavior being flagged (submitted records count as completed; list mode prints a default summary), while mocked discovery methods hide real dependency behavior. Update the contract and its tests together.

CI covers Ruby 3.3, 3.4 and 4.0 in configuration; all three should be green at the final merge commit. A packaging/import smoke test, example smoke tests, and branch coverage reporting would improve release confidence without requiring live network access in normal CI. A separate, explicitly controlled SPN2 smoke test should cover authentication, one capture, polling, cache reuse and screenshot behavior before tagging.

## Product decisions worth making before freezing v2

- **What does “resume” promise?** Recommend preserving the complete input/options and resolving accepted jobs to a terminal outcome, not merely avoiding repeated submissions. This informs M1/M2/S2/D1.
- **What constitutes a successful exit?** Recommend exit 0 only when intended work is accounted for, with explicit incomplete/discovery-failed states and retained recovery data. This informs M2/M3/M5.
- **Should content deduplication remain on by default?** Equal bodies at the same path can still represent distinct URL/host histories; document that the optimization intentionally trades capture completeness for fewer submissions. Ensure it is consistently overridable (M8/S10).
- **Should `--skip-archived` precheck the entire site?** Today it discovers and CDX-checks all candidates before archiving even with a small `--limit`. This is correct for filling the limit but can impose hours of delay on a large site. An incremental check/filter/submit pipeline could stop once enough eligible URLs are selected.
- **How should partial sitemap failure behave?** Skipping one dead child with a warning is an explicit current choice; for unattended preservation, consider surfacing a partial outcome rather than an unqualified successful run.
- **Are screenshots optional artifacts or part of completion?** The best-effort behavior is now documented. Keeping it is reasonable, but a future strict mode and an explicit screenshot-failure field would help callers who require those files. Fix collision and credential handling regardless.

Suggested implementation order: credential/TLS protections; job/session/result invariants; real crawler failures and cancellation; retry scheduling and cross-mode options; reports/examples/documentation. Address findings with HTTP-boundary regression tests so the green suite reflects the release promises.
