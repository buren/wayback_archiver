require 'spec_helper'
require 'tmpdir'

RSpec.describe 'CLI session flags' do
  include CLIHelper

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  # These examples only care about session bookkeeping, not archiving: satisfy
  # the credentials preflight with dummy keys and stub the archive so the run
  # never touches the network.
  before do
    WaybackArchiver.config.access_key = 'test-access'
    WaybackArchiver.config.secret_key = 'test-secret'
    allow(WaybackArchiver).to receive(:archive).and_return([])
  end

  def write_url_file(content, name: 'urls.txt')
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end

  describe '--session' do
    it 'creates a session file at the specified path' do
      session_path = File.join(@tmpdir, 'my_session.jsonl')
      url_file = write_url_file("https://example.com\n")

      # Will fail on network, but session file should be created
      stdout, _stderr, _status = run_cli('--file', url_file, '--session', session_path, '--urls')

      expect(stdout).to include("Session file: #{session_path}")
    end
  end

  describe '--no-session' do
    it 'does not mention session file in output' do
      url_file = write_url_file("https://example.com\n")

      _stdout, stderr, _status = run_cli('--file', url_file, '--no-session', '--urls')

      expect(stderr).not_to include('Session file:')
      expect(stderr).not_to include('Resume with:')
    end
  end

  describe '--resume' do
    it 'raises an error when session file does not exist' do
      _stdout, stderr, status = run_cli(
        'https://example.com',
        '--resume', '/nonexistent/session.jsonl',
        '--urls'
      )

      expect(status).not_to be_success
      expect(stderr).to include('Session file not found')
    end

    it 'logs resuming message when session file exists' do
      session_path = File.join(@tmpdir, 'session.jsonl')
      File.write(session_path, '')
      url_file = write_url_file("https://example.com\n")

      stdout, _stderr, _status = run_cli('--file', url_file, '--resume', session_path, '--urls')

      expect(stdout).to include("Resuming from session: #{session_path}")
    end
  end

  describe 'resume round-trip' do
    it 'skips previously-succeeded URLs and retries the rest on resume' do
      session_path = File.join(@tmpdir, 'roundtrip.jsonl')

      # First run: a.com succeeds, b.com fails. The CLI's archive block writes
      # both to the session file as they complete.
      success = WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')
      failure = WaybackArchiver::ArchiveResult.new('http://b.com', error: StandardError.new('boom'))
      allow(WaybackArchiver).to receive(:archive) do |_urls, **_opts, &block|
        block.call(success)
        block.call(failure)
        [success, failure]
      end

      run_cli('http://a.com', 'http://b.com', '--urls', '--no-summary', "--session=#{session_path}")

      expect(File.exist?(session_path)).to eq(true)

      # Second run resumes: the succeeded URL must be handed to archive as a
      # skip, so only the failed URL is attempted again.
      captured_skip = nil
      allow(WaybackArchiver).to receive(:archive) do |_urls, **opts, &_block|
        captured_skip = opts[:skip_urls]
        []
      end

      run_cli('http://a.com', 'http://b.com', '--urls', '--no-summary', "--resume=#{session_path}")

      expect(captured_skip).to include('http://a.com')
      expect(captured_skip).not_to include('http://b.com')
    end
  end

  describe 'mutually exclusive flags' do
    it 'raises an error when --resume and --session are both given' do
      session_path = File.join(@tmpdir, 'session.jsonl')
      File.write(session_path, '')

      _stdout, stderr, status = run_cli(
        'https://example.com',
        '--resume', session_path,
        '--session', File.join(@tmpdir, 'other.jsonl'),
        '--urls'
      )

      expect(status).not_to be_success
      expect(stderr).to include('--resume and --session are mutually exclusive')
    end

    it 'raises an error when --resume and --no-session are both given' do
      session_path = File.join(@tmpdir, 'session.jsonl')
      File.write(session_path, '')

      _stdout, stderr, status = run_cli(
        'https://example.com',
        '--resume', session_path,
        '--no-session',
        '--urls'
      )

      expect(status).not_to be_success
      expect(stderr).to include('--resume and --no-session are mutually exclusive')
    end
  end
end
