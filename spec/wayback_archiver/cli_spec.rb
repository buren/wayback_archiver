require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'wayback_archiver/cli'

RSpec.describe WaybackArchiver::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def stdout_output
    stdout.string
  end

  def stderr_output
    stderr.string
  end

  def build_cli(*args)
    described_class.new(args, stdout: stdout, stderr: stderr)
  end

  describe '.run' do
    it 'creates an instance and calls run' do
      expect_any_instance_of(described_class).to receive(:run).and_call_original
      allow(WaybackArchiver).to receive(:archive).and_return([])
      described_class.run(['--urls', '--no-session', '--no-summary', 'http://example.com'], stdout: stdout, stderr: stderr)
    end
  end

  describe 'option parsing' do
    it 'parses --concurrency' do
      cli = build_cli('--concurrency=8', 'http://example.com')
      expect(cli.instance_variable_get(:@concurrency)).to eq(8)
    end

    it 'parses --limit' do
      cli = build_cli('--limit=50', 'http://example.com')
      expect(cli.instance_variable_get(:@limit)).to eq(50)
    end

    it 'parses strategy flags' do
      %w[auto crawl sitemap urls rss].each do |strategy|
        cli = build_cli("--#{strategy}", 'http://example.com')
        expect(cli.instance_variable_get(:@strategy)).to eq(strategy)
      end
    end

    it 'parses --check' do
      cli = build_cli('--check', 'http://example.com')
      expect(cli.instance_variable_get(:@check_mode)).to eq(true)
    end

    it 'parses --status' do
      cli = build_cli('--status', 'http://example.com')
      expect(cli.instance_variable_get(:@status_mode)).to eq(true)
    end

    it 'parses --no-summary' do
      cli = build_cli('--no-summary', 'http://example.com')
      expect(cli.instance_variable_get(:@show_summary)).to eq(false)
    end

    it 'parses --no-session' do
      cli = build_cli('--no-session', 'http://example.com')
      expect(cli.instance_variable_get(:@no_session)).to eq(true)
    end

    it 'parses SPN2 capture options' do
      cli = build_cli('--capture-all', '--force-get', 'http://example.com')
      options = cli.instance_variable_get(:@options)
      expect(options[:capture_all]).to eq(true)
      expect(options[:force_get]).to eq(true)
    end

    it 'rejects --concurrency=0' do
      expect { build_cli('--concurrency=0', 'http://example.com') }
        .to raise_error(ArgumentError, /Concurrency/)
    end

    it 'rejects --js-behavior-timeout=31' do
      expect { build_cli('--js-behavior-timeout=31', 'http://example.com') }
        .to raise_error(ArgumentError, /js-behavior-timeout/)
    end
  end

  describe 'validation' do
    it 'rejects --check with --skip-archived' do
      cli = build_cli('--check', '--skip-archived', 'http://example.com')
      expect { cli.run }.to raise_error(ArgumentError, /mutually exclusive/)
    end

    it 'rejects --resume with --session' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, 'session.jsonl')
        File.write(session, '')
        cli = build_cli('--resume', session, '--session', File.join(dir, 'other.jsonl'), 'http://example.com')
        expect { cli.run }.to raise_error(ArgumentError, /mutually exclusive/)
      end
    end

    it 'rejects --resume with --no-session' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, 'session.jsonl')
        File.write(session, '')
        cli = build_cli('--resume', session, '--no-session', 'http://example.com')
        expect { cli.run }.to raise_error(ArgumentError, /mutually exclusive/)
      end
    end

    it 'rejects --resume with nonexistent file' do
      cli = build_cli('--resume', '/tmp/nonexistent-session-file', 'http://example.com')
      expect { cli.run }.to raise_error(ArgumentError, /not found/)
    end

    it 'requires at least one URL' do
      cli = build_cli('--urls')
      expect { cli.run }.to raise_error(ArgumentError, /required/)
    end
  end

  describe 'URL reading' do
    it 'reads URLs from ARGV' do
      cli = build_cli('--urls', 'http://a.com', 'http://b.com')
      # trigger URL reading by running — will fail at archive step
      allow(WaybackArchiver).to receive(:archive).and_return([])
      cli.run
      expect(cli.instance_variable_get(:@urls)).to eq(%w[http://a.com http://b.com])
    end

    it 'reads URLs from --file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n# comment\n\nhttp://b.com\n")
        cli = build_cli('--file', path)
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run
        urls = cli.instance_variable_get(:@urls)
        expect(urls).to eq(%w[http://a.com http://b.com])
      end
    end

    it 'defaults to --urls strategy when --file is used' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n")
        cli = build_cli('--file', path)
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run
        expect(cli.instance_variable_get(:@strategy)).to eq('urls')
      end
    end

    it 'deduplicates URLs from file and ARGV' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n")
        cli = build_cli('--file', path, 'http://a.com')
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run
        urls = cli.instance_variable_get(:@urls)
        expect(urls).to eq(%w[http://a.com])
      end
    end

    it 'raises on missing file' do
      cli = build_cli('--file', '/nonexistent/urls.txt')
      expect { cli.run }.to raise_error(ArgumentError, /File not found/)
    end
  end

  describe 'status mode' do
    it 'prints system and user status' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 10, 'processing' => 2, 'daily_captures' => 50, 'daily_captures_limit' => 300 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(stdout_output).to include('System: ok')
      expect(stdout_output).to include('Available: 10')
      expect(stdout_output).to include('Processing: 2')
      expect(stdout_output).to include('Daily captures: 50/300')
    end

    it 'handles missing credentials' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_raise(WaybackArchiver::AuthenticationError)

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('credentials required')
    end
  end

  describe '#print_summary' do
    it 'tallies results correctly' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000'),
        WaybackArchiver::ArchiveResult.new('http://b.com', status_ext: 'error:blocked-url'),
        WaybackArchiver::ArchiveResult.new('http://c.com', status_ext: 'cached'),
        WaybackArchiver::ArchiveResult.new('http://d.com', status_ext: 'skipped:already-archived'),
      ]

      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, Time.now.to_f)

      expect(stdout_output).to include('Succeeded: 1')
      expect(stdout_output).to include('Failed: 1')
      expect(stdout_output).to include('Cached: 1')
      expect(stdout_output).to include('Skipped: 1')
      expect(stdout_output).to include('Total: 4')
    end
  end

  describe '#build_resume_command' do
    it 'includes strategy, URLs, and session path' do
      cli = build_cli('--crawl', '--concurrency=8', 'http://example.com')
      cli.instance_variable_set(:@urls, ['http://example.com'])
      cli.instance_variable_set(:@strategy, 'crawl')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')
      cli.instance_variable_set(:@session, session)

      cmd = cli.send(:build_resume_command)

      expect(cmd).to include('wayback_archiver')
      expect(cmd).to include('http://example.com')
      expect(cmd).to include('--resume=/tmp/session.jsonl')
      expect(cmd).to include('--crawl')
      expect(cmd).to include('--concurrency=8')
    end
  end

  describe WaybackArchiver::CLIListener do
    let(:listener) { described_class.new(stdout) }

    describe '#on_resolved' do
      it 'prints strategy and URL count' do
        listener.on_resolved(strategy: :sitemap, url_count: 42, source: 'http://example.com')
        expect(stdout_output).to include('sitemap')
        expect(stdout_output).to include('42 URLs')
      end

      it 'prints discovering when url_count is nil' do
        listener.on_resolved(strategy: :crawl, url_count: nil, source: 'http://example.com')
        expect(stdout_output).to include('discovering...')
      end
    end

    describe '#on_completed' do
      it 'prints result with counter' do
        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        listener.on_completed(result: result)

        expect(stdout_output).to include('[1]')
        expect(stdout_output).to include('http://example.com')
      end

      it 'increments counter across calls' do
        result1 = WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')
        result2 = WaybackArchiver::ArchiveResult.new('http://b.com', timestamp: '20240101000000')
        listener.on_completed(result: result1)
        listener.on_completed(result: result2)

        expect(stdout_output).to include('[1]')
        expect(stdout_output).to include('[2]')
      end
    end
  end
end
