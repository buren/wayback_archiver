#!/usr/bin/env ruby
# Process results as they complete using a block.
# Useful for progress reporting or writing results to a file incrementally.
# See also: event_listener.rb for the listener-based approach.

require 'wayback_archiver'

urls = %w[
  https://example.com
  https://example.com/about
  https://example.com/contact
]

# The block is called twice per URL: once when SPN2 accepts the job (an
# interim notification, result.submitted? == true) and again with the final
# outcome. Guard on submitted? or every URL is reported as a failure the
# moment it is queued.
#
# It is also called from several threads at once, so the counter and the
# printing need a lock.
completed = 0
lock = Mutex.new

results = WaybackArchiver.archive(urls, strategy: :urls, concurrency: 4) do |result|
  next if result.submitted?

  lock.synchronize do
    completed += 1
    status = result.success? ? 'OK' : 'FAIL'
    puts "[#{completed}/#{urls.length}] [#{status}] #{result.uri}"
  end
end

puts "\nAll done. #{results.count(&:success?)} succeeded."
