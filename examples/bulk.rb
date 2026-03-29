#!/usr/bin/env ruby
# Archive multiple URLs in parallel.

require 'wayback_archiver'

WaybackArchiver.logger = Logger.new($stdout)

urls = %w[
  https://example.com
  https://example.com/about
  https://example.com/contact
]

# Concurrency controls how many URLs are submitted in parallel.
# Anonymous: 4/min, authenticated: 12/min.
results = WaybackArchiver.archive(urls, strategy: :urls, concurrency: 4)

succeeded = results.count(&:success?)
failed = results.count(&:errored?)
puts "\nDone: #{succeeded} succeeded, #{failed} failed"
