require 'spec_helper'
require 'json'

RSpec.describe WaybackArchiver::WaybackMachine do
  let(:url) { 'https://example.com' }
  let(:job_id) { 'ac58789b-f3ca-48d0-9ea6-1d1225e98695' }
  let(:save_url) { 'https://web.archive.org/save' }
  let(:status_url) { "https://web.archive.org/save/status/#{job_id}" }

  before do
    allow(described_class).to receive(:sleep)
  end

  describe '::call' do
    context 'without authentication' do
      it 'submits URL via POST and polls until success' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url))
          .to_return(
            status: 200,
            body: { url: url, job_id: job_id }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, status_url)
          .to_return(
            status: 200,
            body: {
              status: 'success',
              job_id: job_id,
              original_url: url,
              timestamp: '20260326120000',
              duration_sec: 3.5,
              resources: [url],
              outlinks: {}
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
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

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json)

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

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json)

        described_class.call(url)
      end
    end

    context 'polling' do
      it 'handles pending then success' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(
            { status: 200, body: { status: 'pending', job_id: job_id }.to_json },
            { status: 200, body: { status: 'pending', job_id: job_id }.to_json },
            { status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000', duration_sec: 5.0 }.to_json }
          )

        result = described_class.call(url)

        expect(result.success?).to eq(true)
        expect(result.timestamp).to eq('20260326120000')
      end

      it 'raises PollTimeoutError when polling exceeds timeout' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'pending', job_id: job_id }.to_json)

        # Simulate time passing by making Process.clock_gettime return increasing values
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

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json)

        described_class.call(url, capture_all: true, capture_outlinks: true)
      end

      it 'passes string options as-is' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url, 'if_not_archived_within' => '3d 5h'))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json)

        described_class.call(url, if_not_archived_within: '3d 5h')
      end

      it 'passes integer options as strings' do
        stub_request(:post, save_url)
          .with(body: hash_including('url' => url, 'js_behavior_timeout' => '10'))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json)

        described_class.call(url, js_behavior_timeout: 10)
      end
    end

    context 'error handling' do
      it 'returns ArchiveResult with error fields for non-retryable errors' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(
            status: 200,
            body: {
              status: 'error',
              job_id: job_id,
              status_ext: 'error:invalid-host-resolution',
              message: "Couldn't resolve host"
            }.to_json
          )

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.status_ext).to eq('error:invalid-host-resolution')
        expect(result.job_id).to eq(job_id)
      end

      it 'retries on retryable status_ext errors' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        call_count = 0
        stub_request(:get, status_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              { status: 200, body: { status: 'error', job_id: job_id, status_ext: 'error:too-many-requests', message: 'Rate limited' }.to_json }
            else
              { status: 200, body: { status: 'success', job_id: job_id, timestamp: '20260326120000' }.to_json }
            end
          end

        result = described_class.call(url)
        expect(result.success?).to eq(true)
      end

      it 'returns ArchiveResult with error on network failure' do
        stub_request(:post, save_url).to_raise(Timeout::Error)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
      end
    end

    context 'screenshot' do
      before do
        WaybackArchiver.access_key = 'test-access'
        WaybackArchiver.secret_key = 'test-secret'
      end

      it 'includes screenshot_url in result when capture_screenshot is used' do
        screenshot_url = "http://web.archive.org/screenshot/#{url}"

        stub_request(:post, save_url)
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

        stub_request(:get, status_url)
          .to_return(
            status: 200,
            body: {
              status: 'success', job_id: job_id, timestamp: '20260326120000',
              screenshot: screenshot_url
            }.to_json
          )

        result = described_class.call(url, capture_screenshot: true)
        expect(result.screenshot_url).to eq(screenshot_url)
      end
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
