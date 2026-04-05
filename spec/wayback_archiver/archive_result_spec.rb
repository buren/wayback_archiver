require 'spec_helper'

RSpec.describe WaybackArchiver::ArchiveResult do
  describe '#archived_url' do
    it 'returns the uri' do
      expect(described_class.new('buren').archived_url).to eq('buren')
    end
  end

  describe '#errored?' do
    it 'returns true if error is set' do
      expect(described_class.new(nil, error: true).errored?).to eq(true)
    end

    it 'returns true if status_ext starts with error:' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.errored?).to eq(true)
    end

    it 'returns false if no error and no error status_ext' do
      result = described_class.new('http://example.com')
      expect(result.errored?).to eq(false)
    end
  end

  describe '#error_category' do
    it 'returns :permanent for a permanent status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:blocked-url')
      expect(result.error_category).to eq(:permanent)
    end

    it 'returns :transient for a transient status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:celery')
      expect(result.error_category).to eq(:transient)
    end

    it 'returns :daily_limit for a daily limit status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:too-many-daily-captures')
      expect(result.error_category).to eq(:daily_limit)
    end

    it 'returns nil when status_ext is nil' do
      result = described_class.new('http://example.com')
      expect(result.error_category).to be_nil
    end
  end

  describe '#error_message' do
    it 'returns human-readable message for known status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.error_message).to eq('Target URL not found (HTTP 404)')
    end

    it 'returns nil when status_ext is nil' do
      result = described_class.new('http://example.com')
      expect(result.error_message).to be_nil
    end
  end

  describe '#skipped?' do
    it 'returns true for skipped:already-archived' do
      result = described_class.new('http://example.com', status_ext: 'skipped:already-archived')
      expect(result.skipped?).to eq(true)
    end

    it 'returns false for nil status_ext' do
      result = described_class.new('http://example.com')
      expect(result.skipped?).to eq(false)
    end

    it 'returns false for error status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.skipped?).to eq(false)
    end

    it 'is not errored' do
      result = described_class.new('http://example.com', status_ext: 'skipped:already-archived')
      expect(result.errored?).to eq(false)
    end

    it 'is considered success (archived)' do
      result = described_class.new('http://example.com', status_ext: 'skipped:already-archived')
      expect(result.success?).to eq(true)
    end
  end

  describe '#cached?' do
    it 'returns true for cached status_ext' do
      result = described_class.new('http://example.com', status_ext: 'cached')
      expect(result.cached?).to eq(true)
    end

    it 'returns false for nil status_ext' do
      result = described_class.new('http://example.com')
      expect(result.cached?).to eq(false)
    end

    it 'returns false for error status_ext' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.cached?).to eq(false)
    end

    it 'is not errored' do
      result = described_class.new('http://example.com', status_ext: 'cached')
      expect(result.errored?).to eq(false)
    end

    it 'is considered success' do
      result = described_class.new('http://example.com', status_ext: 'cached')
      expect(result.success?).to eq(true)
    end
  end

  describe '#success?' do
    it 'returns true if no error' do
      expect(described_class.new(nil, error: nil).success?).to eq(true)
    end

    it 'returns false if status_ext is an error' do
      result = described_class.new('http://example.com', status_ext: 'error:blocked-url')
      expect(result.success?).to eq(false)
    end
  end

  describe 'SPN2 fields' do
    let(:result) do
      described_class.new(
        'http://example.com',
        job_id: 'spn2-abc123',
        timestamp: '20260326120000',
        duration_sec: 5.2,
        resources: ['http://example.com/', 'http://example.com/style.css'],
        outlinks: { 'http://other.com' => 'spn2-def456' },
        screenshot_url: 'http://web.archive.org/screenshot/http://example.com/',
        screenshot_path: '/tmp/screenshots/example_com.png',
        status_ext: nil,
        original_url: 'http://example.com/'
      )
    end

    it 'exposes job_id' do
      expect(result.job_id).to eq('spn2-abc123')
    end

    it 'exposes timestamp' do
      expect(result.timestamp).to eq('20260326120000')
    end

    it 'exposes duration_sec' do
      expect(result.duration_sec).to eq(5.2)
    end

    it 'exposes resources' do
      expect(result.resources).to eq(['http://example.com/', 'http://example.com/style.css'])
    end

    it 'exposes outlinks' do
      expect(result.outlinks).to eq({ 'http://other.com' => 'spn2-def456' })
    end

    it 'exposes screenshot_url' do
      expect(result.screenshot_url).to eq('http://web.archive.org/screenshot/http://example.com/')
    end

    it 'exposes screenshot_path' do
      expect(result.screenshot_path).to eq('/tmp/screenshots/example_com.png')
    end

    it 'exposes original_url' do
      expect(result.original_url).to eq('http://example.com/')
    end

    it 'defaults resources to empty array' do
      expect(described_class.new('x').resources).to eq([])
    end

    it 'defaults outlinks to empty hash' do
      expect(described_class.new('x').outlinks).to eq({})
    end
  end

  describe '#wayback_url' do
    it 'returns the wayback URL when timestamp is present' do
      result = described_class.new(
        'http://example.com',
        timestamp: '20260326120000',
        original_url: 'http://example.com/'
      )
      expect(result.wayback_url).to eq('https://web.archive.org/web/20260326120000/http://example.com/')
    end

    it 'falls back to uri when original_url is nil' do
      result = described_class.new('http://example.com', timestamp: '20260326120000')
      expect(result.wayback_url).to eq('https://web.archive.org/web/20260326120000/http://example.com')
    end

    it 'returns nil when timestamp is nil' do
      result = described_class.new('http://example.com')
      expect(result.wayback_url).to be_nil
    end
  end

  describe '.from_status' do
    let(:url) { 'http://example.com' }
    let(:job_id) { 'spn2-abc123' }

    it 'builds a success result from a status hash' do
      status = {
        'status' => 'success',
        'timestamp' => '20260326120000',
        'duration_sec' => 3.5,
        'resources' => [url],
        'outlinks' => {},
        'screenshot' => nil,
        'original_url' => url
      }

      result = described_class.from_status(url, job_id, status)

      expect(result.success?).to eq(true)
      expect(result.job_id).to eq(job_id)
      expect(result.timestamp).to eq('20260326120000')
      expect(result.duration_sec).to eq(3.5)
      expect(result.code).to eq('200')
    end

    it 'handles nil job_id for cached results' do
      status = {
        'status' => 'success',
        'timestamp' => '20260401120000',
        'original_url' => url
      }

      result = described_class.from_status(url, nil, status)

      expect(result.success?).to eq(true)
      expect(result.job_id).to be_nil
      expect(result.timestamp).to eq('20260401120000')
    end

    it 'passes through status_ext on success' do
      status = { 'status' => 'success', 'timestamp' => '20260401120000' }

      result = described_class.from_status(url, nil, status, status_ext: 'cached')

      expect(result.cached?).to eq(true)
      expect(result.status_ext).to eq('cached')
    end

    it 'builds an error result from an error status hash' do
      status = {
        'status' => 'error',
        'status_ext' => 'error:invalid-host-resolution',
        'message' => "Couldn't resolve host"
      }

      result = described_class.from_status(url, job_id, status)

      expect(result.errored?).to eq(true)
      expect(result.status_ext).to eq('error:invalid-host-resolution')
      expect(result.response_error).to eq("Couldn't resolve host")
      expect(result.job_id).to eq(job_id)
    end
  end

  describe '#status_label' do
    it 'returns "ok" for a success result' do
      result = described_class.new('http://example.com')
      expect(result.status_label).to eq('ok')
    end

    it 'returns "FAIL" for an error result' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.status_label).to eq('FAIL')
    end

    it 'returns "cached" for a cached result' do
      result = described_class.new('http://example.com', status_ext: 'cached')
      expect(result.status_label).to eq('cached')
    end

    it 'returns "skip" for a skipped result' do
      result = described_class.new('http://example.com', status_ext: 'skipped:already-archived')
      expect(result.status_label).to eq('skip')
    end

    it 'returns "submit" for a submitted result' do
      result = described_class.new('http://example.com', status_ext: 'submitted')
      expect(result.status_label).to eq('submit')
    end
  end

  describe '#status_detail' do
    it 'returns error message for error results' do
      result = described_class.new('http://example.com', status_ext: 'error:not-found')
      expect(result.status_detail).to eq('Target URL not found (HTTP 404)')
    end

    it 'returns formatted timestamp for cached results' do
      result = described_class.new('http://example.com', status_ext: 'cached', timestamp: '20260401120000')
      expect(result.status_detail).to eq('2026-04-01 12:00:00 UTC')
    end

    it 'returns duration for success results' do
      result = described_class.new('http://example.com', duration_sec: 2.345)
      expect(result.status_detail).to eq('2.3s')
    end

    it 'falls back to error exception message when status_ext is nil' do
      error = StandardError.new('Connection refused')
      result = described_class.new('http://example.com', error: error)
      expect(result.status_detail).to eq('Connection refused')
    end

    it 'returns nil when no detail is available' do
      result = described_class.new('http://example.com')
      expect(result.status_detail).to be_nil
    end
  end

  describe 'backward compatibility' do
    it 'can be constructed with only uri' do
      result = described_class.new('http://example.com')
      expect(result.uri).to eq('http://example.com')
      expect(result.success?).to eq(true)
    end

    it 'can be constructed with uri and error' do
      error = StandardError.new('boom')
      result = described_class.new('http://example.com', error: error)
      expect(result.errored?).to eq(true)
      expect(result.error).to eq(error)
    end
  end
end
