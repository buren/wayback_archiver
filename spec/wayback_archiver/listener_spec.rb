require 'spec_helper'

RSpec.describe WaybackArchiver::NullListener do
  describe 'no-op methods' do
    subject(:listener) { described_class.new }

    it 'responds to on_resolved' do
      expect(listener.on_resolved(strategy: :auto, url_count: 10, source: 'http://example.com')).to be_nil
    end

    it 'responds to on_submitted' do
      expect(listener.on_submitted(url: 'http://example.com', job_id: 'abc')).to be_nil
    end

    it 'responds to on_completed' do
      result = WaybackArchiver::ArchiveResult.new('http://example.com')
      expect(listener.on_completed(result: result)).to be_nil
    end

    it 'responds to on_progress' do
      expect(listener.on_progress(captured: 1, failed: 0, pending: 2)).to be_nil
    end

    it 'responds to on_waiting_for_slots' do
      expect(listener.on_waiting_for_slots(processing: 5)).to be_nil
    end

    it 'responds to on_batch_start' do
      expect(listener.on_batch_start(total: 100)).to be_nil
    end
  end
end

RSpec.describe WaybackArchiver::ListenerProxy do
  describe 'respond_to_missing?' do
    it 'delegates to the wrapped listener' do
      listener = Object.new
      def listener.custom_method; end
      proxy = described_class.new(listener)

      expect(proxy.respond_to?(:custom_method)).to eq(true)
      expect(proxy.respond_to?(:nonexistent_method)).to eq(false)
    end
  end

  describe 'method_missing' do
    it 'delegates unknown methods to the wrapped listener' do
      listener = Object.new
      def listener.custom_method = :delegated
      proxy = described_class.new(listener)

      expect(proxy.custom_method).to eq(:delegated)
    end

    it 'raises NoMethodError for methods the listener does not respond to' do
      proxy = described_class.new(Object.new)

      expect { proxy.totally_unknown_method }.to raise_error(NoMethodError)
    end
  end
end

RSpec.describe 'Listener events' do
  let(:listener) { WaybackArchiver.listener }

  describe 'on_resolved' do
    it 'fires for urls strategy' do
      allow(WaybackArchiver::Archive).to receive(:post).and_return([])

      WaybackArchiver.urls(%w[http://a.com http://b.com])

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first).to eq(
        strategy: :urls, url_count: 2, source: nil
      )
    end

    it 'fires for sitemap strategy' do
      allow(WaybackArchiver::URLCollector).to receive(:sitemap).and_return(%w[http://a.com])
      allow(WaybackArchiver::Archive).to receive(:post).and_return([])

      WaybackArchiver.sitemap('http://example.com')

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first).to eq(
        strategy: :sitemap, url_count: 1, source: 'http://example.com'
      )
    end

    it 'fires for rss strategy' do
      allow(WaybackArchiver::URLCollector).to receive(:feed).and_return(%w[http://a.com])
      allow(WaybackArchiver::Archive).to receive(:post).and_return([])

      WaybackArchiver.rss('http://example.com/feed.xml')

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first).to eq(
        strategy: :rss, url_count: 1, source: 'http://example.com/feed.xml'
      )
    end

    it 'fires for crawl strategy with nil url_count' do
      allow(WaybackArchiver::Archive).to receive(:crawl).and_return([])

      WaybackArchiver.crawl('http://example.com')

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first).to eq(
        strategy: :crawl, url_count: nil, source: 'http://example.com'
      )
    end

    it 'fires once for auto resolving to sitemap' do
      stub_request(:get, 'http://example.com')
        .to_return(status: 200, body: '<html></html>')
      allow(WaybackArchiver::Sitemapper).to receive(:autodiscover)
        .and_return(%w[http://example.com/page1 http://example.com/page2])
      allow(WaybackArchiver::Archive).to receive(:post).and_return([])

      WaybackArchiver.auto('http://example.com')

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first[:strategy]).to eq(:sitemap)
      expect(listener.resolved_events.first[:url_count]).to eq(2)
    end

    it 'fires once for auto resolving to crawl' do
      stub_request(:get, 'http://example.com')
        .to_return(status: 200, body: '<html></html>')
      allow(WaybackArchiver::Sitemapper).to receive(:autodiscover).and_return([])
      allow(WaybackArchiver::FeedParser).to receive(:autodiscover).and_return([])
      allow(WaybackArchiver::Archive).to receive(:crawl).and_return([])

      WaybackArchiver.auto('http://example.com')

      expect(listener.resolved_events.length).to eq(1)
      expect(listener.resolved_events.first[:strategy]).to eq(:crawl)
      expect(listener.resolved_events.first[:url_count]).to be_nil
    end
  end

  describe 'on_submitted and on_completed in batch mode' do
    let(:job1) { 'spn2-job1' }
    let(:job2) { 'spn2-job2' }

    before do
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    end

    it 'fires on_submitted for each URL that gets a job_id' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://b.com').and_return({ 'url' => 'http://b.com', 'job_id' => job2 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' },
        job2 => { 'status' => 'success', 'job_id' => job2, 'timestamp' => '20260326120000', 'original_url' => 'http://b.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com http://b.com])

      expect(listener.submitted_events.length).to eq(2)
      urls = listener.submitted_events.map { |e| e[:url] }
      expect(urls).to contain_exactly('http://a.com', 'http://b.com')
    end

    it 'fires on_completed for success results' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com])

      completed = listener.completed_events
      expect(completed.length).to eq(1)
      expect(completed.first[:result].success?).to eq(true)
    end

    it 'fires on_completed for error results' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'error', 'job_id' => job1, 'status_ext' => 'error:not-found', 'message' => 'Not found' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com])

      completed = listener.completed_events
      expect(completed.length).to eq(1)
      expect(completed.first[:result].errored?).to eq(true)
    end

    it 'fires on_completed for cached results' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})

      WaybackArchiver::Archive.post(%w[http://a.com])

      completed = listener.completed_events
      expect(completed.length).to eq(1)
      expect(completed.first[:result].cached?).to eq(true)
    end

    it 'does not fire on_completed for submitted-only results' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com])

      # on_completed should fire once (for the poll result), not for the submitted interim
      expect(listener.completed_events.length).to eq(1)
      expect(listener.completed_events.first[:result].submitted?).to eq(false)
    end

    it 'coexists with block callback' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => job1 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        job1 => { 'status' => 'success', 'job_id' => job1, 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      block_results = []
      WaybackArchiver::Archive.post(%w[http://a.com]) { |r| block_results << r }

      # Block receives submitted + completed; listener gets on_submitted + on_completed
      expect(block_results.length).to eq(2)
      expect(listener.submitted_events.length).to eq(1)
      expect(listener.completed_events.length).to eq(1)
    end
  end

  describe 'on_batch_start' do
    before do
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    end

    it 'fires at the start of batch_post with post-filtering URL count' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .and_return({ 'url' => 'http://a.com', 'job_id' => 'j1' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'j1' => { 'status' => 'success', 'job_id' => 'j1', 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com http://b.com], skip_urls: Set.new(['http://b.com']))

      expect(listener.batch_start_events.length).to eq(1)
      expect(listener.batch_start_events.first[:total]).to eq(1)
    end
  end

  describe 'on_progress' do
    before do
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 12, 'processing' => 0 })
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    end

    it 'fires during poll cycles' do
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => 'j1' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'j1' => { 'status' => 'success', 'job_id' => 'j1', 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com])

      expect(listener.progress_events).not_to be_empty
      event = listener.progress_events.last
      expect(event).to have_key(:captured)
      expect(event).to have_key(:failed)
      expect(event).to have_key(:pending)
    end
  end

  describe 'on_waiting_for_slots' do
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    end

    it 'fires when no slots are available' do
      call_count = 0
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status) do
        call_count += 1
        if call_count <= 2
          { 'available' => 0, 'processing' => 7 }
        else
          { 'available' => 4, 'processing' => 3 }
        end
      end
      allow(WaybackArchiver::WaybackMachine).to receive(:submit)
        .with('http://a.com').and_return({ 'url' => 'http://a.com', 'job_id' => 'j1' })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return(
        'j1' => { 'status' => 'success', 'job_id' => 'j1', 'timestamp' => '20260326120000', 'original_url' => 'http://a.com' }
      )

      WaybackArchiver::Archive.post(%w[http://a.com])

      expect(listener.waiting_for_slots_events.length).to eq(1)
      expect(listener.waiting_for_slots_events.first[:processing]).to eq(7)
    end
  end
end
