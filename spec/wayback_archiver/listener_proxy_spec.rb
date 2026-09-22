require 'spec_helper'

RSpec.describe WaybackArchiver::ListenerProxy do
  describe 'with an object that implements all methods' do
    it 'delegates all events' do
      listener = WaybackArchiver::TestListener.new
      proxy = described_class.new(listener)

      proxy.on_resolved(strategy: :sitemap, url_count: 5, source: 'http://example.com')
      proxy.on_batch_start(total: 5)
      proxy.on_submitted(url: 'http://example.com', job_id: 'j1')
      result = WaybackArchiver::ArchiveResult.new('http://example.com')
      proxy.on_completed(result: result)
      proxy.on_progress(captured: 1, failed: 0, pending: 2)
      proxy.on_waiting_for_slots(processing: 3)

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.batch_start_events.length).to eq(1)
      expect(listener.submitted_events.length).to eq(1)
      expect(listener.completed_events.length).to eq(1)
      expect(listener.progress_events.length).to eq(1)
      expect(listener.waiting_for_slots_events.length).to eq(1)
    end
  end

  describe 'with an object that implements only some methods' do
    it 'delegates implemented methods and silently skips others' do
      listener = Object.new
      def listener.on_completed(result:)
        @results ||= []
        @results << result
      end
      def listener.results
        @results || []
      end

      proxy = described_class.new(listener)

      # These should not raise
      proxy.on_resolved(strategy: :sitemap, url_count: 5, source: 'http://example.com')
      proxy.on_submitted(url: 'http://example.com', job_id: 'j1')
      proxy.on_progress(captured: 1, failed: 0, pending: 2)
      proxy.on_waiting_for_slots(processing: 3)

      # This should delegate
      result = WaybackArchiver::ArchiveResult.new('http://example.com')
      proxy.on_completed(result: result)
      expect(listener.results.length).to eq(1)
    end
  end

  describe 'with a hash of procs' do
    it 'calls the proc for matching event keys' do
      completed_results = []
      listener = {
        on_completed: ->(result:) { completed_results << result }
      }

      proxy = described_class.new(listener)

      # Non-matching events should not raise
      proxy.on_resolved(strategy: :sitemap, url_count: 5, source: 'http://example.com')
      proxy.on_submitted(url: 'http://example.com', job_id: 'j1')
      proxy.on_progress(captured: 1, failed: 0, pending: 2)
      proxy.on_waiting_for_slots(processing: 3)

      # Matching event should call the proc
      result = WaybackArchiver::ArchiveResult.new('http://example.com')
      proxy.on_completed(result: result)
      expect(completed_results.length).to eq(1)
    end

    it 'supports multiple event procs' do
      resolved = []
      completed = []
      listener = {
        on_resolved: ->(strategy:, url_count:, source:) { resolved << strategy },
        on_completed: ->(result:) { completed << result }
      }

      proxy = described_class.new(listener)

      proxy.on_resolved(strategy: :feed, url_count: 3, source: 'http://example.com')
      result = WaybackArchiver::ArchiveResult.new('http://example.com')
      proxy.on_completed(result: result)

      expect(resolved).to eq([:feed])
      expect(completed.length).to eq(1)
    end
  end

  describe 'with an empty hash' do
    it 'silently skips all events' do
      proxy = described_class.new({})

      expect {
        proxy.on_resolved(strategy: :sitemap, url_count: 5, source: 'http://example.com')
        proxy.on_submitted(url: 'http://example.com', job_id: 'j1')
        proxy.on_completed(result: WaybackArchiver::ArchiveResult.new('http://example.com'))
        proxy.on_progress(captured: 1, failed: 0, pending: 2)
        proxy.on_waiting_for_slots(processing: 3)
      }.not_to raise_error
    end
  end

  describe 'with a NullListener' do
    it 'passes through without error' do
      proxy = described_class.new(WaybackArchiver::NullListener.new)

      expect {
        proxy.on_resolved(strategy: :sitemap, url_count: 5, source: 'http://example.com')
        proxy.on_completed(result: WaybackArchiver::ArchiveResult.new('http://example.com'))
      }.not_to raise_error
    end
  end

  describe 'exception isolation' do
    # A listener is an observer, not a participant. Events fire from pool
    # workers (a raise there is swallowed and the URL vanishes from the
    # results) and from the poll loop (a raise there aborts the whole run).
    it 'logs and swallows an exception from a listener object' do
      boom = Class.new(WaybackArchiver::NullListener) do
        def on_completed(result:)
          raise 'listener exploded'
        end
      end.new

      expect { described_class.new(boom).on_completed(result: nil) }.not_to raise_error
    end

    it 'logs and swallows an exception from a proc listener' do
      proxy = described_class.new(on_progress: ->(**) { raise 'proc exploded' })

      expect { proxy.on_progress(captured: 1, failed: 0, pending: 0) }.not_to raise_error
    end

    it 'keeps dispatching to later events after one raises' do
      seen = []
      proxy = described_class.new(
        on_submitted: ->(**) { raise 'nope' },
        on_completed: ->(result:) { seen << result }
      )

      proxy.on_submitted(url: 'http://a.com', job_id: 'j1')
      proxy.on_completed(result: :ok)

      expect(seen).to eq([:ok])
    end
  end
end
