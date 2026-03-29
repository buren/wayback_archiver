#!/usr/bin/env ruby
# Use a custom adapter instead of the Wayback Machine.
#
# Any object responding to #call(url, **options) works as an adapter.
# This is useful for testing, dry runs, or sending URLs to a different service.

require 'wayback_archiver'

# Simple adapter that prints URLs instead of archiving them
dry_run_adapter = ->(url, **_options) do
  puts "Would archive: #{url}"
  WaybackArchiver::ArchiveResult.new(url, code: '200')
end

WaybackArchiver.adapter = dry_run_adapter

results = WaybackArchiver.archive(
  %w[https://example.com https://example.com/about],
  strategy: :urls
)

puts "\n#{results.length} URLs processed"

# Adapter as a class for more complex logic
class LoggingAdapter
  def initialize(log_file)
    @log_file = log_file
  end

  def call(url, **options)
    File.open(@log_file, 'a') { |f| f.puts("#{Time.now.iso8601} #{url}") }
    WaybackArchiver::ArchiveResult.new(url, code: '200')
  end
end

WaybackArchiver.adapter = LoggingAdapter.new('/tmp/archived_urls.log')

results = WaybackArchiver.archive('https://example.com', strategy: :url)
puts "Logged to /tmp/archived_urls.log"
