#!/usr/bin/env ruby
# Process results as they complete using a block.
# Useful for progress reporting or writing results to a file incrementally.

require 'wayback_archiver'

urls = %w[
  https://example.com
  https://example.com/about
  https://example.com/contact
]

completed = 0

results = WaybackArchiver.archive(urls, strategy: :urls, concurrency: 4) do |result|
  completed += 1
  status = result.success? ? 'OK' : 'FAIL'
  puts "[#{completed}/#{urls.length}] [#{status}] #{result.uri}"
end

puts "\nAll done. #{results.count(&:success?)} succeeded."
