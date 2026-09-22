#!/bin/bash
# Reading URLs from a file.
#
# The --file flag reads one URL per line. Blank lines and lines starting
# with "#" are ignored, so you can organize your list with comments:
#
#   # Production pages
#   https://example.com/
#   https://example.com/about
#
#   # Blog posts
#   https://example.com/blog/post-1

# Basic usage — read URLs from a file
wayback_archiver --file=urls.txt

# Short flag
wayback_archiver -f urls.txt

# Combine file URLs with positional arguments (duplicates are removed)
wayback_archiver https://example.com/extra -f urls.txt

# Pipe URLs from another command via stdin
grep 'example.com' all_urls.txt | wayback_archiver --file=-

# Combine multiple files via stdin
cat list1.txt list2.txt | wayback_archiver --file=-

# Use with other options
wayback_archiver -f urls.txt --concurrency=8 --capture-screenshot --report=results.csv

# Override the default strategy (--file defaults to --urls)
wayback_archiver -f seeds.txt --crawl
