#!/bin/bash
# Two-phase archiving: discover URLs first, then archive separately.
#
# Useful when you want to crawl fast with high concurrency, inspect or
# filter the URL list, and then archive at a slower pace.

# Phase 1: Discover URLs via crawl and save to a file.
# --list-urls prints discovered URLs, one per line, and nothing else.
# (--check would work too, but it spends a CDX lookup per URL at 24/minute —
# hours for a large site — to answer a question this phase isn't asking.)
wayback_archiver https://example.com --crawl --list-urls > urls.txt

# Inspect, filter, or edit the list between phases.
# For example, extract just the URLs:
# urls.txt is already one URL per line; no CSV parsing needed. Cutting the
# first column of a CSV would also corrupt any URL containing a comma.

# Phase 2: Archive from the file at your own pace.
wayback_archiver --file=urls.txt --concurrency=2

# With session tracking so you can resume if interrupted:
wayback_archiver --file=urls.txt --concurrency=2 --session=archive.jsonl

# Or skip URLs you've already archived recently:
wayback_archiver --file=urls.txt --skip-archived=7d
