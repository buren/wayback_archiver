#!/usr/bin/env ruby
# Use event listeners to react to archiving lifecycle events.
#
# Listeners receive structured events from the library, decoupling
# "what happened" from "how to display it." Useful for progress UIs,
# logging, metrics, or custom integrations.

require 'wayback_archiver'

# Option 1: Subclass NullListener (override only the events you care about)
class ProgressListener < WaybackArchiver::NullListener
  def on_resolved(strategy:, url_count:, source:)
    puts "Strategy: #{strategy} (#{url_count || '?'} URLs)"
  end

  def on_completed(result:)
    if result.success?
      puts "  OK  #{result.uri} (#{result.duration_sec&.round(1)}s)"
    elsif result.errored?
      puts "  ERR #{result.uri} - #{result.error_message}"
    end
  end

  def on_progress(captured:, failed:, pending:)
    puts "  ... #{captured} captured, #{failed} failed, #{pending} pending"
  end
end

WaybackArchiver.listener = ProgressListener.new

results = WaybackArchiver.archive(
  %w[https://example.com https://example.com/about],
  strategy: :urls
)

puts "\nDone. #{results.count(&:success?)} succeeded."

# Option 2: Hash of procs (lightweight, no class needed)
WaybackArchiver.listener = {
  on_completed: ->(result:) { puts "Archived: #{result.uri}" if result.success? }
}

WaybackArchiver.archive('https://example.com', strategy: :url)

# Option 3: Any object — only needs to implement the events it cares about
tracker = Object.new
def tracker.on_completed(result:)
  @count = (@count || 0) + 1
end
def tracker.count
  @count || 0
end

WaybackArchiver.listener = tracker
WaybackArchiver.archive('https://example.com', strategy: :url)
puts "Tracker saw #{tracker.count} completions"
