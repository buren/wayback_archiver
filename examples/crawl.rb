#!/usr/bin/env ruby
# Crawl a site and archive all discovered URLs.

require 'wayback_archiver'

WaybackArchiver.logger = Logger.new($stdout)

results = WaybackArchiver.archive(
  'https://example.com',
  strategy: :crawl,
  concurrency: 4,
  limit: 25 # stop after 25 pages; omit or set to -1 for no limit
)

puts "\nArchived #{results.count(&:success?)} of #{results.length} URLs"
