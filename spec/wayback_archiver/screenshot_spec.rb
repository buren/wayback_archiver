require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Screenshot do
  let(:screenshot_url) { 'http://web.archive.org/screenshot/http://example.com/' }
  let(:original_url) { 'http://example.com/' }
  let(:png_data) { "\x89PNG\r\n\x1a\nfake_png_data" }

  describe '.download' do
    context 'with credentials' do
      before do
        WaybackArchiver.access_key = 'key'
        WaybackArchiver.secret_key = 'secret'
      end

      it 'downloads screenshot and saves to directory' do
        Dir.mktmpdir do |dir|
          stub_request(:get, screenshot_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir)

          expect(File.exist?(path)).to eq(true)
          expect(File.read(path)).to eq(png_data)
          expect(path).to end_with('.png')
        end
      end

      it 'sanitizes URL into filename' do
        Dir.mktmpdir do |dir|
          stub_request(:get, screenshot_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir)
          filename = File.basename(path)

          expect(filename).not_to include('/')
          expect(filename).not_to include(':')
        end
      end

      it 'returns the saved file path rooted in the given directory' do
        Dir.mktmpdir do |dir|
          stub_request(:get, screenshot_url)
            .to_return(status: 200, body: png_data)

          path = described_class.download(screenshot_url, original_url, directory: dir)

          expect(path).to start_with(dir)
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
        .with(screenshot_url, original_url, directory: '/tmp')
    end

    it 'returns nil and logs error when download raises' do
      allow(described_class).to receive(:download).and_raise(StandardError, 'network error')

      result = described_class.maybe_download(screenshot_url, original_url, { screenshot_dir: '/tmp' })

      expect(result).to be_nil
    end
  end
end
