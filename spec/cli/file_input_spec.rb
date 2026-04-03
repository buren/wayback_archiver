require 'spec_helper'
require 'tmpdir'

RSpec.describe 'CLI --file flag' do
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

  describe 'file reading' do
    it 'reads URLs from a file' do
      path = write_url_file("https://example.com\nhttps://example.org\n")
      _stdout, stderr, status = run_cli('--file', path)

      # The command will fail trying to archive (no network), but it should
      # get past argument parsing without error
      expect(stderr).not_to include('File not found')
      expect(stderr).not_to include('[<url>] or --file is required')
    end

    it 'reads URLs with -f short flag' do
      path = write_url_file("https://example.com\n")
      _stdout, stderr, _status = run_cli('-f', path)

      expect(stderr).not_to include('File not found')
      expect(stderr).not_to include('[<url>] or --file is required')
    end

    it 'skips blank lines' do
      path = write_url_file("\n\nhttps://example.com\n\n\n")
      _stdout, stderr, _status = run_cli('-f', path)

      expect(stderr).not_to include('[<url>] or --file is required')
    end

    it 'skips comment lines starting with #' do
      path = write_url_file("# This is a comment\nhttps://example.com\n# Another comment\n")
      _stdout, stderr, _status = run_cli('-f', path)

      expect(stderr).not_to include('[<url>] or --file is required')
    end

    it 'reads from stdin when path is -' do
      _stdout, stderr, _status = run_cli('--file=-', stdin_data: "https://example.com\n")

      expect(stderr).not_to include('[<url>] or --file is required')
    end
  end

  describe 'error handling' do
    it 'raises an error when the file does not exist' do
      _stdout, stderr, status = run_cli('--file', '/nonexistent/urls.txt')

      expect(status).not_to be_success
      expect(stderr).to include('File not found')
    end

    it 'raises an error when file has only comments and blank lines' do
      path = write_url_file("# just a comment\n\n  \n")
      _stdout, stderr, status = run_cli('-f', path)

      expect(status).not_to be_success
      expect(stderr).to include('[<url>] or --file is required')
    end
  end

  describe 'combining with ARGV URLs' do
    it 'does not require positional args when --file is given' do
      path = write_url_file("https://example.com\n")
      _stdout, stderr, _status = run_cli('--file', path)

      expect(stderr).not_to include('[<url>] or --file is required')
    end
  end
end
