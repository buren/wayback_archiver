#!/usr/bin/env ruby
# Archive all URLs from an RSS or Atom feed.

require 'wayback_archiver'

WaybackArchiver.logger = Logger.new($stdout)

results = WaybackArchiver.archive(
  'https://example.com/feed.xml',
  strategy: :rss,
  concurrency: 4
)

results.each do |result|
  if result.success?
    puts "Archived: #{result.wayback_url}"
  else
    puts "Failed:   #{result.uri} - #{result.error}"
  end
end
