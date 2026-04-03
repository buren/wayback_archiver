#!/bin/bash
# Two-phase archiving: discover URLs first, then archive separately.
#
# Useful when you want to crawl fast with high concurrency, inspect or
# filter the URL list, and then archive at a slower pace.

# Phase 1: Discover URLs via crawl and save to a file.
# --check with --report writes all discovered URLs without archiving.
wayback_archiver https://example.com --crawl --check --report=discovered.csv

# Inspect, filter, or edit the list between phases.
# For example, extract just the URLs:
tail -n +2 discovered.csv | cut -d',' -f1 > urls.txt

# Phase 2: Archive from the file at your own pace.
wayback_archiver --file=urls.txt --concurrency=2

# With session tracking so you can resume if interrupted:
wayback_archiver --file=urls.txt --concurrency=2 --session=archive.jsonl

# Or skip URLs you've already archived recently:
wayback_archiver --file=urls.txt --skip-archived=7d
