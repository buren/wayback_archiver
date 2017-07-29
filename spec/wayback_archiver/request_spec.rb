require 'spec_helper'

RSpec.describe WaybackArchiver::Request do
  describe '::get' do
    let(:headers) do
      {
        'Accept' => '*/*',
        'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        'User-Agent' => WaybackArchiver.user_agent
      }
    end

    [
      [described_class::ServerError, Timeout::Error],
      [described_class::ServerError, OpenSSL::SSL::SSLError],
      [described_class::ServerError, Net::HTTPBadResponse],
      [described_class::ServerError, Zlib::Error],
      # For some reason the below line causes an ArgumentError exception to be raised instead
      # [described_class::ClientError, SystemCallError],
      [described_class::ClientError, SocketError],
      [described_class::ClientError, IOError]
    ].each do |test_data|
      error_klass, raised_error_klass = test_data

      it "raises #{error_klass} on #{raised_error_klass}" do
        allow_any_instance_of(Net::HTTP).to receive(:request).and_raise(raised_error_klass)

        expect { described_class.get('https://example.com') }.to raise_error(error_klass)
      end
    end

    it 'returns response when server response with HTTP 200' do
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 200, body: 'buren', headers: {})

      result = described_class.get('https://example.com')
      expect(result.code).to eq('200')
    end

    it 'follows redirect when server response with HTTP 3XX' do
      response_headers = { 'location' => '/redirect-path' }
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: response_headers)

      stub_request(:get, 'https://example.com/redirect-path')
        .with(headers: headers)
        .to_return(status: 200, body: 'buren', headers: {})

      result = described_class.get('https://example.com', max_redirects: 1)
      expect(result.code).to eq('200')
      expect(result.uri).to eq('https://example.com/redirect-path')
    end

    it 'raises MaxRedirectError if max redirects is reached' do
      response_headers = { 'location' => '/redirect-path' }
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 301, body: 'buren', headers: response_headers)

      expect do
        described_class.get('https://example.com', max_redirects: 0)
      end.to raise_error(described_class::MaxRedirectError)
    end

    it 'raises UnknownResponseCodeError if server response with unknown HTTP code' do
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 100, body: 'buren', headers: {})

      expect do
        described_class.get('https://example.com')
      end.to raise_error(described_class::UnknownResponseCodeError)
    end

    it 'raises ResponseError if server responded with an error and raise_on_http_error is true' do
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 400, body: 'buren', headers: {})

      expect do
        described_class.get('https://example.com', raise_on_http_error: true)
      end.to raise_error(described_class::ResponseError)
    end

    it 'returns response if server responds with an error and raise_on_http_error is false' do
      stub_request(:get, 'https://example.com/')
        .with(headers: headers)
        .to_return(status: 400, body: 'buren', headers: {})

      result = described_class.get('https://example.com', raise_on_http_error: false)

      expect(result.code).to eq('400')
    end
  end

  describe '::build_response' do
    it 'builds a Response object' do
      expected = described_class::Response.new('200', 'OK', 'buren', 'http://example.com')
      response = described_class.build_response(
        'http://example.com',
        Struct.new(:code, :message, :body).new('200', 'OK', 'buren')
      )

      expect(response).to eq(expected)
    end

    it 'builds a response object that has a #success? method' do
      response = described_class.build_response(
        'http://example.com',
        Struct.new(:code, :message, :body).new('200', 'OK', 'buren')
      )

      expect(response.success?).to eq(true)
    end
  end

  describe '::build_redirect_uri' do
    it 'raises InvalidRedirectError if no location header is found' do
      response = Struct.new(:header).new(location: nil)
      redirect_error = WaybackArchiver::Request::InvalidRedirectError

      expect do
        described_class.build_redirect_uri('', response)
      end.to raise_error(redirect_error)
    end

    it 'adds base URI if location header is relative' do
      base_uri = 'http://example.com'
      response = Struct.new(:header).new('location' => '/path')
      result = described_class.build_redirect_uri(base_uri, response)

      expect(result).to eq(URI.parse('http://example.com/path'))
    end

    it 'returns location header' do
      base_uri = 'http://example.com'
      response = Struct.new(:header).new('location' => 'https://example.com/path')
      result = described_class.build_redirect_uri(base_uri, response)

      expect(result).to eq(URI.parse('https://example.com/path'))
    end
  end

  describe '::build_uri' do
    it 'returns URI untouched if passed an instance of URI' do
      uri = URI.parse('http://example.com')
      expect(described_class.build_uri(uri)).to eq(uri)
    end

    it 'returns URI instance if passed string with http protocol' do
      uri = URI.parse('http://example.com')
      expect(described_class.build_uri('http://example.com')).to eq(uri)
    end

    it 'returns URI instance if passed string with https protocol' do
      uri = URI.parse('https://example.com')
      expect(described_class.build_uri('https://example.com')).to eq(uri)
    end

    it 'returns URI instance with protocol if passed string without protocol' do
      uri = URI.parse('http://example.com')
      expect(described_class.build_uri('example.com')).to eq(uri)
    end
  end

  describe '::parse_body' do
    it 'returns empty string if passed nil' do
      expect(described_class.parse_body(nil)).to eq('')
    end

    it 'returns string untouched if passed a regular string' do
      expect(described_class.parse_body('buren')).to eq('buren')
    end

    it 'returns uncompressed string if passed a gzipped string' do
      gzipped_string = File.read('spec/data/test_gzip.gz')
      expect(described_class.parse_body(gzipped_string)).to eq("buren\n")
    end
  end

  describe '::blank?' do
    it 'returns true if passed nil' do
      expect(described_class.blank?(nil)).to eq(true)
    end

    it 'returns true if passed empty string' do
      expect(described_class.blank?('')).to eq(true)
    end

    it 'returns true if passed string with only spaces' do
      expect(described_class.blank?('  ')).to eq(true)
    end

    it 'returns false if passed non-string empty' do
      expect(described_class.blank?('buren')).to eq(false)
    end
  end
end
