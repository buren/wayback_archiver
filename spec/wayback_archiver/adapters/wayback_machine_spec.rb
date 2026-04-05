require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe WaybackArchiver::WaybackMachine do
  let(:url) { 'https://example.com' }
  let(:job_id) { 'ac58789b-f3ca-48d0-9ea6-1d1225e98695' }
  let(:save_url) { 'https://web.archive.org/save' }
  let(:status_url) { "https://web.archive.org/save/status/#{job_id}" }

  before do
    WaybackArchiver.config.access_key = 'test-access'
    WaybackArchiver.config.secret_key = 'test-secret'
    # Re-disable rate limiting after setting credentials (setters call reset_rate_limiter!)
    described_class.instance_variable_set(
      :@rate_limiter,
      WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false)
    )
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
    context 'without credentials' do
      it 'raises AuthenticationError' do
        WaybackArchiver.config.access_key = nil
        WaybackArchiver.config.secret_key = nil

        expect { described_class.call(url) }
          .to raise_error(WaybackArchiver::AuthenticationError, /credentials required/i)
      end
    end

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

    it 'sends Authorization header' do
      stub_request(:post, save_url)
        .with(headers: { 'Authorization' => 'LOW test-access:test-secret' })
        .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
      stub_status(success_status)

      described_class.call(url)
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

      it 'sends Accept and Authorization headers on status polls' do
        stub_submit
        stub_status(success_status)

        described_class.call(url)

        expect(WebMock).to have_requested(:get, status_url)
          .with(headers: {
            'Accept' => 'application/json',
            'Authorization' => 'LOW test-access:test-secret'
          })
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

    context 'log output' do
      it 'formats the timestamp as human-readable UTC' do
        stub_submit
        stub_status(success_status(timestamp: '20260403114428'))

        allow(WaybackArchiver.logger).to receive(:info)
        expect(WaybackArchiver.logger).to receive(:info).with("Captured #{url} [2026-04-03 11:44:28 UTC]")

        described_class.call(url)
      end

      it 'passes through non-standard timestamps as-is' do
        stub_submit
        stub_status(success_status(timestamp: 'unknown'))

        allow(WaybackArchiver.logger).to receive(:info)
        expect(WaybackArchiver.logger).to receive(:info).with("Captured #{url} [unknown]")

        described_class.call(url)
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

      it 'passes remaining boolean options as "1"' do
        stub_request(:post, save_url)
          .with(body: hash_including(
            'url' => url,
            'delay_wb_availability' => '1',
            'skip_first_archive' => '1',
            'outlinks_availability' => '1',
            'email_result' => '1'
          ))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url,
          delay_wb_availability: true,
          skip_first_archive: true,
          outlinks_availability: true,
          email_result: true
        )
      end

      it 'passes remaining value options as strings' do
        stub_request(:post, save_url)
          .with(body: hash_including(
            'url' => url,
            'capture_cookie' => 'session=abc',
            'target_username' => 'user1',
            'target_password' => 'pass1'
          ))
          .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)
        stub_status(success_status)

        described_class.call(url,
          capture_cookie: 'session=abc',
          target_username: 'user1',
          target_password: 'pass1'
        )
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

      it 'retries when submit returns session limit error' do
        call_count = 0
        stub_request(:post, save_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              { status: 200, body: { 'message' => 'You have already reached the limit of active Save Page Now sessions. Please wait for a minute and then try again.' }.to_json }
            else
              { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
            end
          end
        stub_status(success_status)

        result = described_class.call(url)
        expect(result.success?).to eq(true)
        expect(call_count).to be > 1
      end

      it 'retries connection errors and succeeds' do
        call_count = 0
        stub_request(:post, save_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              raise Errno::ECONNREFUSED, 'Connection refused'
            else
              { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
            end
          end
        stub_status(success_status)

        result = described_class.call(url)
        expect(result.success?).to eq(true)
        expect(call_count).to be > 1
      end

      it 'returns ArchiveResult with error after exhausting connection retries' do
        stub_request(:post, save_url).to_raise(Errno::ECONNREFUSED)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::Request::Error)
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
        expect(result.error.message).to include('something unexpected')
      end

      it 'surfaces auth-required message from SPN2 response' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { 'message' => 'You need to be logged in to use Save Page Now.' }.to_json)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::Request::ServerError)
        expect(result.error.message).to include('You need to be logged in')
      end

      it 'returns ArchiveResult with error when retries exhausted on RetryableError' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: {
            'status' => 'error', 'status_ext' => 'error:too-many-requests'
          }.to_json)

        # Force Retry.with_backoff to give up by raising RetryableError through all retries
        allow(WaybackArchiver::Retry).to receive(:with_backoff).and_raise(
          WaybackArchiver::RetryableError, 'error:too-many-requests'
        )

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error).to be_a(WaybackArchiver::RetryableError)
        expect(result.status_ext).to eq('error:too-many-requests')
      end

      it 'retries when submit returns retryable status_ext without job_id' do
        call_count = 0
        stub_request(:post, save_url)
          .to_return do |_request|
            call_count += 1
            if call_count <= 1
              { status: 200, body: { 'status_ext' => 'error:too-many-requests' }.to_json }
            else
              { status: 200, body: { 'url' => url, 'job_id' => job_id }.to_json }
            end
          end
        stub_status(success_status)

        result = described_class.call(url)
        expect(result.success?).to eq(true)
        expect(call_count).to be > 1
      end

      it 'includes URL in error when response has no message' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: { 'status' => 'error' }.to_json)

        result = described_class.call(url)

        expect(result.errored?).to eq(true)
        expect(result.error.message).to include(url)
      end
    end

    context 'cached result from if_not_archived_within' do
      it 'returns successful result when submit returns a capture directly (no job_id)' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: {
            'url' => url, 'status' => 'success',
            'timestamp' => '20260401120000', 'duration_sec' => 0.0,
            'original_url' => url, 'resources' => [url]
          }.to_json)

        result = described_class.call(url, if_not_archived_within: '7d')

        expect(result.success?).to eq(true)
        expect(result.cached?).to eq(true)
        expect(result.timestamp).to eq('20260401120000')
        expect(result.job_id).to be_nil
      end

      it 'does not poll when submit returns a cached capture' do
        stub_request(:post, save_url)
          .to_return(status: 200, body: {
            'url' => url, 'timestamp' => '20260401120000'
          }.to_json)

        result = described_class.call(url, if_not_archived_within: '7d')

        expect(result.success?).to eq(true)
        # No status poll requests should have been made
        expect(WebMock).not_to have_requested(:get, /save\/status/)
      end
    end

    context 'screenshot' do
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

    it 'raises Request::Error on network failure' do
      stub_request(:post, save_url).to_raise(Timeout::Error)

      expect { described_class.submit(url) }.to raise_error(WaybackArchiver::Request::Error)
    end

    it 'returns ArchiveResult with error when response is not JSON' do
      stub_request(:post, save_url)
        .to_return(status: 200, body: '<html>Error</html>')

      result = described_class.submit(url)
      expect(result).to be_a(WaybackArchiver::ArchiveResult)
      expect(result.errored?).to eq(true)
      expect(result.error).to be_a(JSON::ParserError)
    end

    it 'sends auth headers' do
      stub_request(:post, save_url)
        .with(headers: { 'Authorization' => 'LOW test-access:test-secret' })
        .to_return(status: 200, body: { url: url, job_id: job_id }.to_json)

      described_class.submit(url)
    end

    it 'raises AuthenticationError without credentials' do
      WaybackArchiver.config.access_key = nil
      WaybackArchiver.config.secret_key = nil

      expect { described_class.submit(url) }
        .to raise_error(WaybackArchiver::AuthenticationError)
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

    it 'sends auth headers' do
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
      stub_request(:get, /web\.archive\.org\/save\/status\/user\?_t=/)
        .to_return(status: 200, body: '{"available":12,"processing":3}')

      status = described_class.check_user_status
      expect(status['available']).to eq(12)
      expect(status['processing']).to eq(3)
    end

    it 'sends Accept and Authorization headers' do
      stub_request(:get, /web\.archive\.org\/save\/status\/user\?_t=/)
        .to_return(status: 200, body: '{"available":12,"processing":3}')

      described_class.check_user_status

      expect(WebMock).to have_requested(:get, /save\/status\/user/)
        .with(headers: {
          'Accept' => 'application/json',
          'Authorization' => 'LOW test-access:test-secret'
        })
    end

    it 'raises AuthenticationError without credentials' do
      WaybackArchiver.config.access_key = nil
      WaybackArchiver.config.secret_key = nil

      expect do
        described_class.check_user_status
      end.to raise_error(WaybackArchiver::AuthenticationError)
    end

    it 'raises ServerError when response is not JSON' do
      stub_request(:get, /web\.archive\.org\/save\/status\/user\?_t=/)
        .to_return(status: 200, body: '<html>Bad Gateway</html>')

      expect { described_class.check_user_status }
        .to raise_error(WaybackArchiver::Request::ServerError, /Invalid JSON/)
    end
  end

  describe '::system_status' do
    let(:system_status_url) { 'https://web.archive.org/save/status/system' }

    it 'returns parsed JSON from /save/status/system' do
      stub_request(:get, system_status_url)
        .to_return(status: 200, body: '{"status":"ok"}')

      status = described_class.system_status
      expect(status['status']).to eq('ok')
    end

    it 'does not require credentials' do
      WaybackArchiver.config.access_key = nil
      WaybackArchiver.config.secret_key = nil

      stub_request(:get, system_status_url)
        .to_return(status: 200, body: '{"status":"ok"}')

      expect { described_class.system_status }.not_to raise_error
    end

    it 'raises ServerError on non-JSON response' do
      stub_request(:get, system_status_url)
        .to_return(status: 200, body: '<html>Error</html>')

      expect { described_class.system_status }
        .to raise_error(WaybackArchiver::Request::ServerError, /Invalid JSON/)
    end

    it 'raises on network timeout' do
      stub_request(:get, system_status_url).to_raise(Timeout::Error)

      expect { described_class.system_status }
        .to raise_error(WaybackArchiver::Request::ServerError)
    end
  end
end
