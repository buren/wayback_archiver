#!/usr/bin/env ruby
# Write archive results to a CSV or JSON report file.
# Format is auto-detected from the file extension.

require 'wayback_archiver'
require 'wayback_archiver/report'

WaybackArchiver.logger = Logger.new($stdout)

results = WaybackArchiver.archive(
  %w[https://example.com https://example.com/about],
  strategy: :urls,
  concurrency: 4
)

# Write CSV report
WaybackArchiver::Report.write(results, 'report.csv')
puts "CSV report written to report.csv"

# Write JSON report
WaybackArchiver::Report.write(results, 'report.json')
puts "JSON report written to report.json"
