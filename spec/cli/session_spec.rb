require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'CLI session flags' do
  let(:bin) { File.expand_path('../../bin/wayback_archiver', __dir__) }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def run_cli(*args, stdin_data: nil)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, bin, *args, stdin_data: stdin_data)
    [stdout, stderr, status]
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
