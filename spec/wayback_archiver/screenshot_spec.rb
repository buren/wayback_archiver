require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Screenshot do
  let(:screenshot_url) { 'http://web.archive.org/screenshot/http://example.com/' }
  let(:timestamp) { '20260920202839' }
  let(:replay_url) { "https://web.archive.org/web/#{timestamp}/#{screenshot_url}" }
  let(:original_url) { 'http://example.com/' }
  let(:png_data) { "\x89PNG\r\n\x1a\nfake_png_data" }
  let(:jpeg_data) { "\xFF\xD8\xFF\xE0fake_jpeg_data".b }

  describe '.download' do
    context 'with credentials' do
      before do
        WaybackArchiver.config.access_key = 'key'
        WaybackArchiver.config.secret_key = 'secret'
      end

      it 'downloads screenshot and saves to directory' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)

          expect(File.exist?(path)).to eq(true)
          expect(File.read(path)).to eq(png_data)
          expect(path).to end_with('.png')
        end
      end

      it 'sanitizes URL into filename' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)
          filename = File.basename(path)

          expect(filename).not_to include('/')
          expect(filename).not_to include(':')
        end
      end

      it 'returns the saved file path rooted in the given directory' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)

          expect(path).to start_with(dir)
          expect(path).to end_with('.png')
        end
      end

      # Regression: a smoke test caught a 404 HTML error page being written
      # to disk as a .png and logged as "Screenshot saved to ...", with the
      # bogus path recorded in the report's screenshot_path.
      it 'raises instead of saving an HTTP error body as a PNG' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url)
            .to_return(status: 404, body: '<!doctype html><title>404 Not Found</title>')

          expect { described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp) }
            .to raise_error(WaybackArchiver::Request::ResponseError)
          expect(Dir.children(dir)).to be_empty
        end
      end

      it 'raises instead of saving a 200 response that is not an image' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url)
            .to_return(status: 200, body: '<!doctype html><title>Login</title>')

          expect { described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp) }
            .to raise_error(WaybackArchiver::Request::ServerError, /not an image/i)
          expect(Dir.children(dir)).to be_empty
        end
      end

      it 'sends the Internet Archive credentials it insists on having' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url).to_return(status: 200, body: png_data)

          described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)

          expect(WebMock).to have_requested(:get, replay_url)
            .with(headers: { 'Authorization' => 'LOW key:secret' })
        end
      end

      it 'keeps credentials through relative and same-origin HTTPS redirects' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url).to_return(status: 302, headers: { 'Location' => '/image' })
          stub_request(:get, 'https://web.archive.org/image')
            .to_return(status: 302, headers: { 'Location' => 'https://WEB.ARCHIVE.ORG:443/final' })
          stub_request(:get, 'https://web.archive.org/final').to_return(body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)

          expect(File.binread(path)).to eq(png_data.b)
          [replay_url, 'https://web.archive.org/image', 'https://web.archive.org/final'].each do |url|
            expect(WebMock).to have_requested(:get, url).with(headers: { 'Authorization' => 'LOW key:secret' })
          end
        end
      end

      {
        'a foreign host' => 'https://other.example/image',
        'a different port' => 'https://web.archive.org:8443/image',
        'an HTTPS downgrade' => 'http://web.archive.org/image',
        'a scheme-relative foreign host' => '//other.example/image',
        'a lookalike hostname' => 'https://web.archive.org.other.example/image',
        'URL credentials' => 'https://user:password@web.archive.org/image',
        'a non-HTTP scheme' => 'ftp://web.archive.org/image'
      }.each do |description, location|
        it "rejects a redirect to #{description} before requesting it" do
          Dir.mktmpdir do |dir|
            stub_request(:get, replay_url).to_return(status: 302, headers: { 'Location' => location })
            # The transport must not even be constructed for an unsafe target.
            allow(WaybackArchiver::Request).to receive(:build_http).and_call_original

            expect do
              described_class.download(screenshot_url, original_url, directory: dir, timestamp: timestamp)
            end.to raise_error(WaybackArchiver::Request::InvalidRedirectError, /origin/i)

            expect(WaybackArchiver::Request).to have_received(:build_http).once
            expect(Dir.children(dir)).to be_empty
            expect(WaybackArchiver.logger.debug_log.join).not_to include('password')
          end
        end
      end

      [nil, ''].each do |missing_timestamp|
        it "rejects the raw HTTP screenshot URL when timestamp is #{missing_timestamp.inspect}" do
          Dir.mktmpdir do |dir|
            stub_request(:get, screenshot_url).to_return(body: png_data)

            expect do
              described_class.download(screenshot_url, original_url, directory: dir, timestamp: missing_timestamp)
            end.to raise_error(WaybackArchiver::Request::InvalidRedirectError, /origin/i)

            expect(WebMock).not_to have_requested(:get, screenshot_url)
            expect(Dir.children(dir)).to be_empty
          end
        end
      end

      it 'rejects an off-origin HTTPS screenshot URL without a timestamp' do
        Dir.mktmpdir do |dir|
          target = 'https://other.example/image'
          stub_request(:get, target).to_return(body: png_data)

          expect do
            described_class.download(target, original_url, directory: dir)
          end.to raise_error(WaybackArchiver::Request::InvalidRedirectError, /origin/i)

          expect(WebMock).not_to have_requested(:get, target)
          expect(Dir.children(dir)).to be_empty
        end
      end

      it 'allows a trusted HTTPS screenshot URL without a timestamp' do
        Dir.mktmpdir do |dir|
          stub_request(:get, replay_url).to_return(body: png_data)

          path = described_class.download(replay_url, original_url, directory: dir)

          expect(File.binread(path)).to eq(png_data.b)
          expect(WebMock).to have_requested(:get, replay_url)
            .with(headers: { 'Authorization' => 'LOW key:secret' })
        end
      end

      # SPN2's `screenshot` field is the URL the image was archived *under*,
      # not a live endpoint: fetching it directly 404s, including the example
      # in the official SPN2 docs. The image is a separate Wayback capture and
      # only resolves through the replay path for that capture's timestamp.
      it 'fetches the screenshot through the Wayback replay path' do
        Dir.mktmpdir do |dir|
          replay = "https://web.archive.org/web/20260920202839/#{screenshot_url}"
          stub_request(:get, replay).to_return(status: 200, body: jpeg_data,
                                               headers: { 'Content-Type' => 'image/jpg' })

          described_class.download(screenshot_url, original_url,
                                   directory: dir, timestamp: '20260920202839')

          expect(WebMock).to have_requested(:get, replay)
        end
      end

      # Despite the docs saying PNG, archive.org serves image/jpg.
      it 'accepts a JPEG and names the file accordingly' do
        Dir.mktmpdir do |dir|
          stub_request(:get, %r{web\.archive\.org/web/}).to_return(
            status: 200, body: jpeg_data, headers: { 'Content-Type' => 'image/jpg' }
          )

          path = described_class.download(screenshot_url, original_url,
                                          directory: dir, timestamp: '20260920202839')

          expect(path).to end_with('.jpg')
          expect(File.binread(path)).to eq(jpeg_data)
        end
      end

      it 'still accepts a PNG' do
        Dir.mktmpdir do |dir|
          stub_request(:get, %r{web\.archive\.org/web/}).to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url,
                                          directory: dir, timestamp: '20260920202839')

          expect(path).to end_with('.png')
        end
      end

      it 'raises ArgumentError if directory does not exist' do
        expect do
          described_class.download(screenshot_url, original_url, directory: '/nonexistent/path')
        end.to raise_error(ArgumentError, /directory/i)
      end
    end

    context 'without credentials' do
      it 'raises AuthenticationError' do
        Dir.mktmpdir do |dir|
          expect do
            described_class.download(screenshot_url, original_url, directory: dir)
          end.to raise_error(WaybackArchiver::AuthenticationError)
        end
      end
    end
  end

  describe '.maybe_download' do
    it 'returns nil when screenshot_url is nil' do
      result = described_class.maybe_download(nil, original_url, { screenshot_dir: '/tmp' })
      expect(result).to be_nil
    end

    it 'returns nil when screenshot_dir is not in options' do
      result = described_class.maybe_download(screenshot_url, original_url, {})
      expect(result).to be_nil
    end

    it 'delegates to download when both screenshot_url and screenshot_dir are present' do
      allow(described_class).to receive(:download).and_return('/tmp/screenshot.png')

      result = described_class.maybe_download(screenshot_url, original_url, { screenshot_dir: '/tmp' })

      expect(result).to eq('/tmp/screenshot.png')
      expect(described_class).to have_received(:download)
        .with(screenshot_url, original_url, directory: '/tmp', timestamp: nil)
    end

    it 'returns nil and writes nothing when the screenshot 404s' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.config.access_key = 'key'
        WaybackArchiver.config.secret_key = 'secret'
        stub_request(:get, replay_url).to_return(status: 404, body: 'nope')

        result = described_class.maybe_download(screenshot_url, original_url, { screenshot_dir: dir },
                                               timestamp: timestamp)

        expect(result).to be_nil
        expect(Dir.children(dir)).to be_empty
      end
    end

    it 'returns nil and logs error when download raises' do
      allow(described_class).to receive(:download).and_raise(StandardError, 'network error')

      result = described_class.maybe_download(screenshot_url, original_url, { screenshot_dir: '/tmp' })

      expect(result).to be_nil
    end
  end

  describe 'capture result integration' do
    it 'keeps a successful capture when an unsafe screenshot redirect is rejected' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.config.access_key = 'key'
        WaybackArchiver.config.secret_key = 'secret'
        target = 'https://other.example/image'
        stub_request(:get, replay_url).to_return(status: 302, headers: { 'Location' => '/image' })
        stub_request(:get, 'https://web.archive.org/image')
          .to_return(status: 302, headers: { 'Location' => target })
        stub_request(:get, target).to_return(body: png_data)
        status = { 'status' => 'success', 'timestamp' => timestamp, 'screenshot' => screenshot_url }

        result = WaybackArchiver::ArchiveResult.from_status(original_url, 'job-id', status, screenshot_dir: dir)

        expect(result).to be_success
        expect(result.screenshot_url).to eq(screenshot_url)
        expect(result.screenshot_path).to be_nil
        expect(WaybackArchiver.logger.error_log.join).to match(/Failed to download screenshot:.*origin/i)
        expect(WebMock).not_to have_requested(:get, target)
        expect(Dir.children(dir)).to be_empty
      end
    end
  end
end
