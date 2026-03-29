#!/usr/bin/env ruby
# Archive all URLs found in a sitemap.
# Supports sitemap indexes, gzipped sitemaps, and recursive discovery.

require 'wayback_archiver'

WaybackArchiver.logger = Logger.new($stdout)

results = WaybackArchiver.archive(
  'https://example.com/sitemap.xml',
  strategy: :sitemap,
  concurrency: 4,
  limit: 50 # cap at 50 URLs; omit or set to -1 for no limit
)

results.each do |result|
  status = result.success? ? 'OK' : 'FAIL'
  puts "[#{status}] #{result.uri}"
end
