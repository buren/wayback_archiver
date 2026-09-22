require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'

# Smoke tests for the runnable scripts in examples/.
#
# They are published as the documented way to use the gem, so a broken one is
# as bad as a broken feature — and until now nothing executed them. Each
# example is loaded into this process with the SPN2 endpoints and the example
# site stubbed (see spec/support/doc_fixtures.rb): a raised exception, a typo'd
# method or an unstubbed request all fail the example.
RSpec.describe 'examples' do
  include DocFixtures

  EXAMPLES_DIR = File.expand_path('../examples', __dir__)

  # Loading a script runs it. Redirect $stdout first: the examples log to it,
  # and Logger.new($stdout) captures whatever $stdout is at that moment.
  def run_example(name)
    path = File.join(EXAMPLES_DIR, name)
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    begin
      load path
    ensure
      $stdout = original
    end
    captured.string
  end

  before do
    # The examples read credentials from the environment (ENV[] via
    # Configuration, ENV.fetch in the two that configure explicitly).
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return('test-ak')
    allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return('test-sk')
    allow(ENV).to receive(:fetch).with('WAYBACK_ACCESS_KEY').and_return('test-ak')
    allow(ENV).to receive(:fetch).with('WAYBACK_SECRET_KEY').and_return('test-sk')

    # An example that calls WaybackArchiver.configure rebuilds the capture rate
    # limiter, so disable it at the source rather than on the instance.
    allow(WaybackArchiver::RateLimiter).to receive(:for_current_user)
      .and_return(WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false))

    stub_documented_endpoints!
  end

  it 'lists every example in examples/README.md' do
    listed = File.read(File.join(EXAMPLES_DIR, 'README.md')).scan(/\[([^\]]+\.(?:rb|sh))\]/).flatten.uniq
    present = Dir.children(EXAMPLES_DIR).grep(/\.(rb|sh)\z/).sort

    expect(listed.sort).to eq(present)
  end

  describe 'basic.rb' do
    it 'archives one URL and prints the snapshot link' do
      output = run_example('basic.rb')

      expect(output).to include("Archived: #{DocFixtures::WAYBACK}/web/#{DocFixtures::CAPTURE_TIMESTAMP}/https://example.com")
      expect(output).to include('Job ID:   spn2-job-')
      expect(output).not_to include('Failed:')
    end
  end

  describe 'bulk.rb' do
    it 'archives every URL in the list' do
      output = run_example('bulk.rb')

      expect(output).to include('Done: 3 succeeded, 0 failed, 0 unconfirmed')
    end
  end

  describe 'crawl.rb' do
    it 'crawls the site and reports how many URLs were archived' do
      output = run_example('crawl.rb')

      expect(output).to match(/Archived (\d+) of \1 URLs/)
      expect(output).not_to match(/Archived 0 of/)
    end
  end

  describe 'sitemap.rb' do
    it 'archives the URLs listed in the sitemap' do
      output = run_example('sitemap.rb')

      expect(output).to include('[OK] https://example.com/')
      expect(output).to include('[OK] https://example.com/about')
      expect(output).not_to include('[FAIL]')
    end
  end

  describe 'rss_feed.rb' do
    it 'archives the URLs in the feed' do
      output = run_example('rss_feed.rb')

      expect(output.scan(/^Archived: /).length).to eq(2)
      expect(output).not_to include('Failed:')
    end
  end

  describe 'streaming_results.rb' do
    it 'reports each URL once, when it finishes rather than when it is queued' do
      output = run_example('streaming_results.rb')

      lines = output.lines.grep(/^\[\d+\/3\]/)
      expect(lines.length).to eq(3)
      expect(lines.join).not_to include('[FAIL]')
      expect(output).to include('All done. 3 succeeded.')
    end
  end

  describe 'event_listener.rb' do
    it 'drives all three listener styles' do
      output = run_example('event_listener.rb')

      expect(output).to include('Strategy: urls (2 URLs)')
      expect(output).to include('  OK  https://example.com')
      expect(output).to include('Done. 2 succeeded.')
      expect(output).to include('Archived: https://example.com') # hash-of-procs listener
      expect(output).to include('Tracker saw 1 completions')     # duck-typed listener
    end
  end

  describe 'report.rb' do
    around { |example| Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } } }

    it 'writes both report files' do
      output = run_example('report.rb')

      expect(output).to include('CSV report written to report.csv')
      expect(File.read('report.csv')).to include('https://example.com/about')
      expect(JSON.parse(File.read('report.json')).length).to eq(2)
    end
  end

  describe 'screenshots.rb' do
    # The example saves into examples/screenshots, next to itself.
    let(:screenshot_dir) { File.join(EXAMPLES_DIR, 'screenshots') }

    after { FileUtils.rm_rf(screenshot_dir) }

    it 'downloads the screenshot to disk' do
      output = run_example('screenshots.rb')

      expect(output).to include('Screenshot saved: ')
      expect(Dir.children(screenshot_dir).grep(/\.png\z/)).not_to be_empty
    end
  end

  describe 'track_outlinks.rb' do
    it 'polls each outlink job to a terminal status' do
      output = run_example('track_outlinks.rb')

      expect(output).to include('Outlinks: 1 captured')
      expect(output).to include("Polling outlink: https://example.com/about (job: #{DocFixtures::OUTLINK_JOB})")
      expect(output).to include("Archived: #{DocFixtures::WAYBACK}/web/#{DocFixtures::CAPTURE_TIMESTAMP}/https://example.com/about")
      expect(output).not_to include('Gave up waiting')
    end
  end
end
