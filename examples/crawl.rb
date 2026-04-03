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

# Crawl across subdomains using hosts (strings or regex patterns)
# results = WaybackArchiver.archive(
#   'https://www.example.com',
#   strategy: :crawl,
#   hosts: ['www.example.com', 'blog.example.com'],
#   limit: 50
# )
#
# Regex pattern to match all subdomains:
# hosts: [/.*\.example\.com/]
