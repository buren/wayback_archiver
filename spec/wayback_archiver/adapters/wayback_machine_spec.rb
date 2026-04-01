require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe WaybackArchiver::WaybackMachine do
  let(:url) { 'https://example.com' }
  let(:job_id) { 'ac58789b-f3ca-48d0-9ea6-1d1225e98695' }
  let(:save_url) { 'https://web.archive.org/save' }
  let(:status_url) { "https://web.archive.org/save/status/#{job_id}" }

  before do
    allow(described_class).to receive(:sleep)
    allow(WaybackArchiver::Retry).to receive(:sleep)
  end

  def stub_submit(response_body = { url: url, job_id: job_id })
    stub_request(:post, save_url)
      .to_return(status: 200, body: response_body.to_json)
  end

  def stub_status(*responses)
    stub_request(:get, status_url)
      .to_return(responses.map { |r| { status: 200, body: r.to_json } })
  end

  def success_status(extra = {})
    { status: 'success', job_id: job_id, timestamp: '20260326120000' }.merge(extra)
  end

  describe '::call' do
    context 'without authentication' do
      it 'submits URL via POST and polls until success' do
        stub_submit(url: url, job_id: job_id)
        stub_status(
          status: 'success', job_id: job_id, original_url: url,
          timestamp: '20260326120000', duration_sec: 3.5,
          resources: [url], outlinks: {}
        )

        result = described_class.call(url)

        expect(result).to be_a(WaybackArchiver::ArchiveResult)
        expect(result.uri).to eq(url)
        expect(result.job_id).to eq(job_id)
        expect(result.timestamp).to eq('20260326120000')
        expect(result.duration_sec).to eq(3.5)
        expect(result.resources).to eq([url])
        expect(result.original_url).to eq(url)
        expect(result.success?).to eq(true)
      end

      it 'does not send Authorization header' do
        stub_request(:post, save_url)
          .with { |req| !req.headers.key?('Authorization') }
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url)
      end
    end

    context 'with authentication' do
      before do
        WaybackArchiver.access_key = 'test-access'
        WaybackArchiver.secret_key = 'test-secret'
      end

      it 'sends Authorization header' do
        stub_request(:post, save_url)
          .with(headers: { 'Authorization' => 'LOW test-access:test-secret' })
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url)
      end
    end

    context 'polling' do
      it 'handles pending then success' do
        stub_submit
        stub_status(
          { status: 'pending', job_id: job_id },
          { status: 'pending', job_id: job_id },
          success_status(duration_sec: 5.0)
        )

        result = described_class.call(url)

        expect(result.success?).to eq(true)
        expect(result.timestamp).to eq('20260326120000')
      end

      it 'returns PollTimeoutError when polling exceeds timeout' do
        stub_submit
        stub_status(status: 'pending', job_id: job_id)

        start_time = 100.0
        allow(Process).to receive(:clock_gettime).and_return(start_time, start_time + 130)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::WaybackMachine::PollTimeoutError)
      end
    end

    context 'SPN2 options' do
      it 'passes boolean options as "1" in POST body' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url, 'capture_all' => '1', 'capture_outlinks' => '1'))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url, capture_all: true, capture_outlinks: true)
      end

      it 'passes string options as-is' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url, 'if_not_archived_within' => '3d 5h'))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url, if_not_archived_within: '3d 5h')
      end

      it 'passes integer options as strings' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url, 'js_behavior_timeout' => '10'))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url, js_behavior_timeout: 10)
      end
    end

    context 'error handling' do
      it 'returns ArchiveResult with error fields for non-retryable errors' do
        stub_submit
        stub_status(status: 'error', job_id: job_id, status_ext: 'error:invalid-host-resolution', message: "Couldn't resolve host")

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.status_ext).to eq('error:invalid-host-resolution')
        expect(result.job_id).to eq(job_id)
      end

      it 'retries on retryable status_ext errors' do
        stub_submit

        call_count = 0
        stub_request(:get, status_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              { status: 200, body: { status: 'error', job_id: job_id, status_ext: 'error:too-many-requests', message: 'Rate limited' }.to_json }
            else
              { status: 200, body: success_status.to_json }
            end
          end

        result = described_class.call(url)
        expect(result.success?).to eq(true)
      end

      it 'retries on newly retryable status_ext errors (e.g. gateway-timeout)' do
        stub_submit

        call_count = 0
        stub_request(:get, status_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              { status: 200, body: { status: 'error', job_id: job_id, status_ext: 'error:gateway-timeout', message: 'Timeout' }.to_json }
            else
              { status: 200, body: success_status.to_json }
            end
          end

        result = described_class.call(url)
        expect(result.success?).to eq(true)
      end

      it 'does not retry daily_limit errors' do
        stub_submit
        stub_status(status: 'error', job_id: job_id, status_ext: 'error:too-many-daily-captures', message: 'Captured 10 times today')

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.status_ext).to eq('error:too-many-daily-captures')
        expect(result.error_category).to eq(:daily_limit)
      end

      it 'returns ArchiveResult with error on network failure' do
        stub_request(:post, save_url).to_raise(Timeout::Error)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
      end

      it 'returns ArchiveResult with error when submit returns non-JSON' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: '<html>Service Unavailable</html>')

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(JSON::ParserError)
      end

      it 'returns ArchiveResult with error when poll returns non-JSON' do
        stub_submit
        stub_request(:get, status_url)
          .to_return(status: 200, body: '<html>Bad Gateway</html>')

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(JSON::ParserError)
      end

      it 'returns ArchiveResult with error when submit response has no job_id' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { 'message' => 'something unexpected' }.to_json)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
        expect(result.error.message).to include('Missing job_id')
      end
    end

    context 'screenshot' do
      before do
        WaybackArchiver.access_key = 'test-access'
        WaybackArchiver.secret_key = 'test-secret'
      end

      let(:screenshot_remote_url) { "http://web.archive.org/screenshot/#{url}" }

      it 'includes screenshot_url in result when capture_screenshot is used' do
        stub_submit
        stub_status(success_status(screenshot: screenshot_remote_url))

        result = described_class.call(url, capture_screenshot: true)
        expect(result.screenshot_url).to eq(screenshot_remote_url)
      end

      it 'downloads screenshot when screenshot_dir is provided' do
        Dir.mktmpdir do |dir|
          png_data = "\x89PNG\r\n\x1a\nfake"

          stub_submit
          stub_status(success_status(screenshot: screenshot_remote_url, original_url: url))
          stub_request(:get, screenshot_remote_url).to_return(status: 200, body: png_data)

          result = described_class.call(url, capture_screenshot: true, screenshot_dir: dir)

          expect(result.screenshot_path).to be_a(String)
          expect(File.exist?(result.screenshot_path)).to eq(true)
          expect(File.read(result.screenshot_path)).to eq(png_data)
        end
      end

      it 'skips screenshot download when screenshot field is absent' do
        Dir.mktmpdir do |dir|
          stub_submit
          stub_status(success_status)

          result = described_class.call(url, capture_screenshot: true, screenshot_dir: dir)

          expect(result.screenshot_path).to be_nil
          expect(result.screenshot_url).to be_nil
        end
      end
    end
  end

  describe '::submit' do
    it 'POSTs to /save and returns url and job_id hash' do
      stub_submit
      result = described_class.submit(url)
      expect(result).to eq({ 'url' => url, 'job_id' => job_id })
    end

    it 'includes SPN2 options in POST body' do
      stub_request(:post, save_url)
        .with(body: hash_including('url' => url, 'capture_all' => '1'))
        .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

      described_class.submit(url, capture_all: true)
    end

    it 'returns ArchiveResult with error on network failure' do
      stub_request(:post, save_url).to_raise(Timeout::Error)

      result = described_class.submit(url)
      expect(result).to be_a(WaybackArchiver::ArchiveResult)
      expect(result.errored?).to eq(true)
    end

    it 'returns ArchiveResult with error when response is not JSON' do
      stub_request(:post, save_url)
        .to_return(status: 200, body: '<html>Error</html>')

      result = described_class.submit(url)
      expect(result).to be_a(WaybackArchiver::ArchiveResult)
      expect(result.errored?).to eq(true)
      expect(result.error).to be_a(JSON::ParserError)
    end

    it 'sends auth headers when credentials configured' do
      WaybackArchiver.access_key = 'test-access'
      WaybackArchiver.secret_key = 'test-secret'

      stub_request(:post, save_url)
        .with(headers: { 'Authorization' => 'LOW test-access:test-secret' })
        .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

      described_class.submit(url)
    end
  end

  describe '::poll_statuses' do
    let(:job_id_2) { 'bbbb789b-f3ca-48d0-9ea6-1d1225e98695' }
    let(:batch_status_url) { 'https://web.archive.org/save/status' }

    it 'POSTs to /save/status with comma-separated job_ids' do
      stub_request(:post, batch_status_url)
        .with(body: hash_including('job_ids' => "#{job_id},#{job_id_2}"))
        .to_return(
          status: 200,
          body: {
            job_id => { 'status' => 'success', 'job_id' => job_id, 'timestamp' => '20260326120000' },
            job_id_2 => { 'status' => 'pending', 'job_id' => job_id_2 }
          }.to_json
        )

      result = described_class.poll_statuses([job_id, job_id_2])

      expect(result.keys).to contain_exactly(job_id, job_id_2)
      expect(result[job_id]['status']).to eq('success')
      expect(result[job_id_2]['status']).to eq('pending')
    end

    it 'sends auth headers when credentials configured' do
      WaybackArchiver.access_key = 'test-access'
      WaybackArchiver.secret_key = 'test-secret'

      stub_request(:post, batch_status_url)
        .with(headers: { 'Authorization' => 'LOW test-access:test-secret' })
        .to_return(status: 200, body: { job_id => { 'status' => 'success' } }.to_json)

      described_class.poll_statuses([job_id])
    end

    it 'raises ServerError when response is not JSON' do
      stub_request(:post, batch_status_url)
        .to_return(status: 200, body: '<html>Bad Gateway</html>')

      expect { described_class.poll_statuses([job_id]) }
        .to raise_error(WaybackArchiver::Request::ServerError, /Invalid JSON/)
    end
  end

  describe '::check_user_status' do
    it 'returns available and processing counts' do
      WaybackArchiver.access_key = 'test-access'
      WaybackArchiver.secret_key = 'test-secret'

      stub_request(:get, /web\.archive\.org\/save\/status\/user\?_t=/)
        .to_return(status: 200, body: '{"available":12,"processing":3}')

      status = described_class.check_user_status
      expect(status['available']).to eq(12)
      expect(status['processing']).to eq(3)
    end

    it 'raises AuthenticationError without credentials' do
      expect do
        described_class.check_user_status
      end.to raise_error(WaybackArchiver::AuthenticationError)
    end
  end
end
