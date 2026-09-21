#!/usr/bin/env ruby
# Download screenshots of archived pages.
# Requires authentication.

require 'wayback_archiver'

WaybackArchiver.configure do |config|
  config.access_key = ENV.fetch('WAYBACK_ACCESS_KEY')
  config.secret_key = ENV.fetch('WAYBACK_SECRET_KEY')
end

WaybackArchiver.config.logger = Logger.new($stdout)

screenshot_dir = File.expand_path('screenshots', __dir__)
Dir.mkdir(screenshot_dir) unless Dir.exist?(screenshot_dir)

results = WaybackArchiver.archive(
  'https://example.com',
  strategy: :url,
  capture_screenshot: true,
  screenshot_dir: screenshot_dir
)

results.each do |result|
  if result.screenshot_path
    puts "Screenshot saved: #{result.screenshot_path}"
  elsif result.screenshot_url
    # Not a fetchable URL: it is the address the image was archived *under*,
    # and requesting it directly returns 404. Reaching it means replaying it
    # through the Wayback Machine at the capture's timestamp, which is what
    # screenshot_dir does for you.
    puts "SPN2 reported a screenshot for #{result.uri} but it could not be downloaded"
  else
    puts "No screenshot for: #{result.uri}"
  end
end
