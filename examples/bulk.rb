#!/usr/bin/env ruby
# Archive multiple URLs in parallel.

require 'wayback_archiver'

WaybackArchiver.config.logger = Logger.new($stdout)

urls = %w[
  https://example.com
  https://example.com/about
  https://example.com/contact
]

# Concurrency controls how many URLs are submitted in parallel.
# SPN2 rate limit: 12 captures/min.
results = WaybackArchiver.archive(urls, strategy: :urls, concurrency: 4)

succeeded = results.count(&:success?)
failed = results.count(&:errored?)
puts "\nDone: #{succeeded} succeeded, #{failed} failed"
