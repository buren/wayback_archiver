#!/usr/bin/env ruby
# Track outlink captures manually.
#
# When capture_outlinks: true, the Wayback Machine captures linked pages
# in the background. The result includes a hash of outlink URLs to their
# job IDs. This example shows how to poll those jobs yourself.

require 'wayback_archiver'
require 'json'

WaybackArchiver.configure do |config|
  config.access_key = ENV.fetch('WAYBACK_ACCESS_KEY')
  config.secret_key = ENV.fetch('WAYBACK_SECRET_KEY')
end

WaybackArchiver.config.logger = Logger.new($stdout)

# Archive with outlink capture enabled
results = WaybackArchiver.archive(
  'https://example.com',
  strategy: :url,
  capture_outlinks: true
)

result = results.first
puts "Archived: #{result.wayback_url}"
puts "Outlinks: #{result.outlinks.length} captured"

# Poll each outlink job to check its status
result.outlinks.each do |outlink_url, job_id|
  puts "\nPolling outlink: #{outlink_url} (job: #{job_id})"

  loop do
    response = WaybackArchiver::Request.get(
      "#{WaybackArchiver::WaybackMachine::STATUS_URL}/#{job_id}",
      follow_redirects: false
    )
    status = JSON.parse(response.body)

    case status['status']
    when 'success'
      ts = status['timestamp']
      puts "  Archived: https://web.archive.org/web/#{ts}/#{outlink_url}"
      break
    when 'pending'
      sleep(3)
    else
      puts "  Failed: #{status['status_ext']}"
      break
    end
  end
end
