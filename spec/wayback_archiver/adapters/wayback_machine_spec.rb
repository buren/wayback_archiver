require 'spec_helper'

RSpec.describe WaybackArchiver::WaybackMachine do
  let(:headers) do
    {
      'Accept' => '*/*',
      'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
      'User-Agent' => WaybackArchiver.user_agent
    }
  end

  describe '::call' do
    it 'posts URL to the Wayback Machine' do
      url = 'https://example.com'
      expected_request_url = "https://web.archive.org/save/#{url}"

      stub_request(:get, expected_request_url)
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: {})

      result = described_class.call(url)

      expect(result.uri).to eq(url)
      expect(result.code).to eq('301')
      expect(WaybackArchiver.logger.debug_log.first).to include(expected_request_url)
      expect(WaybackArchiver.logger.info_log.last).to include(url)
    end

    it 'rescues and logs Request::ServerError' do
      allow(WaybackArchiver::Request).to receive(:get)
        .and_raise(WaybackArchiver::Request::MaxRedirectError, 'too many redirects')

      url = 'https://example.com'
      expected_request_url = "https://web.archive.org/save/#{url}"

      stub_request(:get, expected_request_url)
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: {})

      result = described_class.call(url)

      expect(result.uri).to eq(url)
      expect(result.response_error).to be_nil
      expect(result.request_url).to be_nil
      expect(result.error).to be_a(WaybackArchiver::Request::MaxRedirectError)

      last_error_log = WaybackArchiver.logger.error_log.last
      expect(last_error_log).to include(url)
      expect(last_error_log).to include('MaxRedirectError')
      expect(last_error_log).to include('too many redirects')
    end
  end
end
