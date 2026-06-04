require 'spec_helper'
require 'tmpdir'

RSpec.describe 'CLI --check flag' do
  include CLIHelper

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def write_url_file(content, name: 'urls.txt')
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end

  describe '--check' do
    it 'does not mention session file' do
      url_file = write_url_file("https://example.com\n")
      allow(WaybackArchiver).to receive(:check).and_return([])

      stdout, _stderr, _status = run_cli('--check', '--file', url_file, '--urls')

      expect(stdout).not_to include('Session file:')
    end

    it 'applies URL filters before checking' do
      url_file = write_url_file("https://example.com/a.pdf\nhttps://example.com/b.html\n")
      allow(WaybackArchiver).to receive(:check).and_return([])

      run_cli('--check', '--file', url_file, '--urls', '--exclude-ext', 'pdf')

      expect(WaybackArchiver).to have_received(:check)
        .with(['https://example.com/b.html'], concurrency: anything)
    end
  end

  describe 'mutually exclusive flags' do
    it 'raises an error when --check and --skip-archived are both given' do
      _stdout, stderr, status = run_cli(
        'https://example.com',
        '--check',
        '--skip-archived',
        '--urls'
      )

      expect(status).not_to be_success
      expect(stderr).to include('--check and --skip-archived are mutually exclusive')
    end
  end
end
