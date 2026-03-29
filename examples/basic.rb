#!/usr/bin/env ruby
# Archive a single URL with the Wayback Machine.

require 'wayback_archiver'

# Optional: configure credentials for higher rate limits
# WaybackArchiver.configure do |config|
#   config.access_key = 'your-access-key'
#   config.secret_key = 'your-secret-key'
# end

# Enable logging to see what's happening
WaybackArchiver.logger = Logger.new($stdout)

results = WaybackArchiver.archive('https://example.com', strategy: :url)

results.each do |result|
  if result.success?
    puts "Archived: #{result.wayback_url}"
    puts "  Job ID:   #{result.job_id}"
    puts "  Duration: #{result.duration_sec}s"
  else
    puts "Failed: #{result.uri} - #{result.error}"
  end
end
