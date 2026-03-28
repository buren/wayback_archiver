require 'spec_helper'
require 'tmpdir'

RSpec.describe WaybackArchiver::Screenshot do
  let(:screenshot_url) { 'http://web.archive.org/screenshot/http://example.com/' }
  let(:original_url) { 'http://example.com/' }
  let(:png_data) { "\x89PNG\r\n\x1a\nfake_png_data" }

  describe '.download' do
    it 'downloads screenshot and saves to directory' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.access_key = 'key'
        WaybackArchiver.secret_key = 'secret'

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
        WaybackArchiver.access_key = 'key'
        WaybackArchiver.secret_key = 'secret'

        stub_request(:get, screenshot_url)
          .to_return(status: 200, body: png_data)

        path = described_class.download(screenshot_url, original_url, directory: dir)

        filename = File.basename(path)
        expect(filename).not_to include('/')
        expect(filename).not_to include(':')
      end
    end

    it 'raises AuthenticationError without credentials' do
      Dir.mktmpdir do |dir|
        expect do
          described_class.download(screenshot_url, original_url, directory: dir)
        end.to raise_error(WaybackArchiver::AuthenticationError)
      end
    end

    it 'raises ArgumentError if directory does not exist' do
      WaybackArchiver.access_key = 'key'
      WaybackArchiver.secret_key = 'secret'

      expect do
        described_class.download(screenshot_url, original_url, directory: '/nonexistent/path')
      end.to raise_error(ArgumentError, /directory/i)
    end

    it 'returns the saved file path' do
      Dir.mktmpdir do |dir|
        WaybackArchiver.access_key = 'key'
        WaybackArchiver.secret_key = 'secret'

        stub_request(:get, screenshot_url)
          .to_return(status: 200, body: png_data)

        path = described_class.download(screenshot_url, original_url, directory: dir)

        expect(path).to start_with(dir)
        expect(path).to end_with('.png')
      end
    end
  end
end
