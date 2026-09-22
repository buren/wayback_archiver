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

  describe '--check with --report' do
    # Regression: Report.write only knew .csv/.json while ReportWriter also
    # accepted .jsonl — so '--check --report=out.jsonl' completed the entire
    # CDX scan, then crashed, and the report was never written.
    it 'writes a .jsonl check report' do
      report_path = File.join(@tmpdir, 'check.jsonl')
      results = [
        WaybackArchiver::CheckResult.new('https://example.com/a', archived: true, timestamp: '20260101000000'),
        WaybackArchiver::CheckResult.new('https://example.com/b', archived: false)
      ]
      allow(WaybackArchiver).to receive(:check).and_return(results)

      _stdout, _stderr, status = run_cli(
        'https://example.com/a', 'https://example.com/b', '--check', '--urls', "--report=#{report_path}"
      )

      expect(status).to be_success
      lines = File.readlines(report_path)
      expect(lines.length).to eq(2)
      expect(JSON.parse(lines.first)['url']).to eq('https://example.com/a')
    end
  end

  describe 'check result output' do
    # Regression: a failed CDX lookup (web.archive.org down/rate-limiting)
    # was printed as '✗ (not archived)' with exit 0 — indistinguishable from
    # a genuinely unarchived URL, even though every check may have failed.
    it 'distinguishes failed checks from not-archived and exits nonzero' do
      results = [
        WaybackArchiver::CheckResult.new('https://example.com/a', archived: true, timestamp: '20260101000000'),
        WaybackArchiver::CheckResult.new('https://example.com/b', archived: false),
        WaybackArchiver::CheckResult.new('https://example.com/c', archived: false,
                                         error: WaybackArchiver::Request::ServerError.new('503 Service Unavailable'))
      ]
      allow(WaybackArchiver).to receive(:check).and_return(results)

      stdout, _stderr, status = run_cli(
        'https://example.com/a', 'https://example.com/b', 'https://example.com/c', '--check', '--urls'
      )

      expect(stdout).to match(%r{✓ https://example\.com/a})
      expect(stdout).to include('✗ https://example.com/b  (not archived)')
      expect(stdout).to include('? https://example.com/c  (check failed: 503 Service Unavailable)')
      expect(stdout).to include('1 archived, 1 not archived, 1 check failed')
      expect(status).not_to be_success
    end

    it 'exits 0 when all checks complete without errors' do
      results = [
        WaybackArchiver::CheckResult.new('https://example.com/a', archived: true, timestamp: '20260101000000'),
        WaybackArchiver::CheckResult.new('https://example.com/b', archived: false)
      ]
      allow(WaybackArchiver).to receive(:check).and_return(results)

      stdout, _stderr, status = run_cli('https://example.com/a', 'https://example.com/b', '--check', '--urls')

      expect(stdout).to include('1 archived, 1 not archived')
      expect(stdout).not_to include('check failed')
      expect(status).to be_success
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
