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

  describe 'option parsing edge cases' do
    it 'rejects --limit=0' do
      expect { build_cli('--limit=0', 'http://example.com') }
        .to raise_error(ArgumentError, /Limit/)
    end

    it 'accepts --limit=-1 for unlimited' do
      cli = build_cli('--limit=-1', 'http://example.com')
      expect(cli.instance_variable_get(:@limit)).to eq(-1)
    end

    it 'rejects invalid --hosts regex' do
      expect { build_cli('--hosts=[invalid', 'http://example.com') }
        .to raise_error(ArgumentError, /Invalid host pattern/)
    end

    it 'parses --hosts as array of Regexp' do
      cli = build_cli('--hosts=example\\.com,other\\.org', 'http://example.com')
      hosts = cli.instance_variable_get(:@hosts)
      expect(hosts.length).to eq(2)
      expect(hosts).to all(be_a(Regexp))
    end

    it 'parses --skip-archived without value' do
      cli = build_cli('--skip-archived', 'http://example.com')
      expect(cli.instance_variable_get(:@skip_archived)).to eq(true)
      expect(cli.instance_variable_get(:@skip_archived_within)).to be_nil
    end

    it 'parses --skip-archived with timedelta value' do
      cli = build_cli('--skip-archived=7d', 'http://example.com')
      expect(cli.instance_variable_get(:@skip_archived)).to eq(true)
      expect(cli.instance_variable_get(:@skip_archived_within)).to eq('7d')
    end

    it 'parses --report' do
      cli = build_cli('--report=/tmp/out.csv', 'http://example.com')
      expect(cli.instance_variable_get(:@report_path)).to eq('/tmp/out.csv')
    end

    it 'parses --quiet to set FATAL log level' do
      cli = build_cli('--quiet', 'http://example.com')
      expect(cli.instance_variable_get(:@log_level)).to eq(Logger::FATAL)
    end

    it 'parses --verbose to set DEBUG log level' do
      cli = build_cli('--verbose', 'http://example.com')
      expect(cli.instance_variable_get(:@log_level)).to eq(Logger::DEBUG)
    end

    it 'parses --no-verbose to set WARN log level' do
      cli = build_cli('--no-verbose', 'http://example.com')
      expect(cli.instance_variable_get(:@log_level)).to eq(Logger::WARN)
    end
  end

  describe '#setup_logger' do
    it 'creates a logger at the configured level' do
      cli = build_cli('--verbose', '--urls', '--no-session', '--no-summary', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])
      cli.run

      logger = WaybackArchiver.config.logger
      expect(logger).to be_a(Logger)
      expect(logger.level).to eq(Logger::DEBUG)
    end
  end

  describe '#setup_session' do
    it 'creates auto-generated session when no flags given' do
      cli = build_cli('--urls', '--no-summary', 'http://example.com')
      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)

      # Auto-generated session gets deleted on success, but we can verify the flag was set
      cli.run

      # auto_generated_session is set to true, session deleted on success (set to nil)
      expect(cli.instance_variable_get(:@auto_generated_session)).to eq(true)
      expect(cli.instance_variable_get(:@session)).to be_nil
    end

    it 'creates session at custom path with --session' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'custom.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{path}", 'http://example.com')
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run

        session = cli.instance_variable_get(:@session)
        expect(session.path).to eq(path)
        expect(cli.instance_variable_get(:@auto_generated_session)).to eq(false)
        session.delete!
      end
    end

    it 'resumes from existing session file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'session.jsonl')
        File.write(path, '{"url":"http://done.com","success":true,"submitted":false}' + "\n")
        cli = build_cli('--urls', '--no-summary', "--resume=#{path}", 'http://example.com')
        allow(WaybackArchiver).to receive(:archive).and_return([])
        cli.run

        skip_urls = cli.instance_variable_get(:@skip_urls)
        expect(skip_urls).to include('http://done.com')
      end
    end

    it 'sets no session with --no-session' do
      cli = build_cli('--urls', '--no-summary', '--no-session', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])
      cli.run

      expect(cli.instance_variable_get(:@session)).to be_nil
    end
  end

  describe '#cleanup_session' do
    it 'deletes auto-generated session when all results succeed' do
      cli = build_cli('--urls', '--no-summary', 'http://example.com')

      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)
      cli.run

      # Auto-generated session is deleted on success
      expect(cli.instance_variable_get(:@auto_generated_session)).to eq(true)
      expect(cli.instance_variable_get(:@session)).to be_nil
    end

    it 'keeps session and prints resume command when results have errors' do
      Dir.mktmpdir do |dir|
        session_path = File.join(dir, 'session.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{session_path}", 'http://example.com')

        results = [WaybackArchiver::ArchiveResult.new('http://example.com', error: StandardError.new('fail'))]
        allow(WaybackArchiver).to receive(:archive).and_return(results)
        cli.run

        expect(File.exist?(session_path)).to eq(true)
        expect(stderr_output).to include('Resume with:')
      end
    end
  end

  describe '#write_report' do
    it 'writes a report when --report is set' do
      Dir.mktmpdir do |dir|
        report_path = File.join(dir, 'report.json')
        cli = build_cli('--urls', '--no-session', '--no-summary', "--report=#{report_path}", 'http://example.com')

        results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
        allow(WaybackArchiver).to receive(:archive).and_return(results)
        cli.run

        expect(File.exist?(report_path)).to eq(true)
        data = JSON.parse(File.read(report_path))
        expect(data.length).to eq(1)
        expect(data.first['url']).to eq('http://example.com')
      end
    end

    it 'does nothing when --report is not set' do
      cli = build_cli('--urls', '--no-session', '--no-summary', 'http://example.com')
      results = [WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')]
      allow(WaybackArchiver).to receive(:archive).and_return(results)

      expect { cli.run }.not_to raise_error
    end
  end

  describe '#run_archive' do
    it 'passes options through to WaybackArchiver.archive' do
      cli = build_cli('--urls', '--no-session', '--no-summary', '--capture-all', '--force-get', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli.run

      expect(WaybackArchiver).to have_received(:archive).with(
        'http://example.com',
        hash_including(
          strategy: 'urls',
          capture_all: true,
          force_get: true
        )
      )
    end

    it 'yields results to session writer' do
      Dir.mktmpdir do |dir|
        session_path = File.join(dir, 'session.jsonl')
        cli = build_cli('--urls', '--no-summary', "--session=#{session_path}", 'http://example.com')

        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        allow(WaybackArchiver).to receive(:archive).and_yield(result).and_return([result])
        cli.run

        lines = File.readlines(session_path)
        expect(lines.length).to eq(1)
        data = JSON.parse(lines.first)
        expect(data['url']).to eq('http://example.com')
      end
    end
  end

  describe 'status mode' do
    it 'handles system status error gracefully' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_raise(StandardError.new('connection refused'))
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 10, 'processing' => 2 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('unreachable')
      expect(stdout_output).to include('connection refused')
    end

    it 'handles user status error gracefully' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_raise(StandardError.new('network error'))

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('System: ok')
      expect(stdout_output).to include('unreachable')
    end

    it 'omits daily captures when not present' do
      allow(WaybackArchiver::WaybackMachine).to receive(:system_status)
        .and_return({ 'status' => 'ok' })
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 5, 'processing' => 1 })

      cli = build_cli('--status')
      expect { cli.run }.to raise_error(SystemExit)

      expect(stdout_output).to include('Available: 5')
      expect(stdout_output).not_to include('Daily captures:')
    end
  end

  describe '#print_summary' do
    it 'shows submitted count when present' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', job_id: 'j1', status_ext: 'submitted'),
      ]

      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, Process.clock_gettime(Process::CLOCK_MONOTONIC))

      expect(stdout_output).to include('Submitted: 1')
    end

    it 'shows error breakdown by category' do
      results = [
        WaybackArchiver::ArchiveResult.new('http://a.com', status_ext: 'error:too-many-requests'),
        WaybackArchiver::ArchiveResult.new('http://b.com', status_ext: 'error:too-many-daily-captures'),
        WaybackArchiver::ArchiveResult.new('http://c.com', status_ext: 'error:blocked-url'),
      ]

      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, Process.clock_gettime(Process::CLOCK_MONOTONIC))

      expect(stdout_output).to include('transient')
      expect(stdout_output).to include('daily limit')
      expect(stdout_output).to include('permanent')
    end

    it 'formats duration as seconds for short runs' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 42.0
      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, start)

      expect(stdout_output).to include('Duration: 42s')
    end

    it 'formats duration as minutes and seconds' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 754.0
      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, start)

      expect(stdout_output).to include('Duration: 12m 34s')
    end

    it 'formats duration as hours, minutes, and seconds' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5025.0
      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, start)

      expect(stdout_output).to include('Duration: 1h 23m 45s')
    end

    it 'clamps sub-second durations to 1s' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 0.1
      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, start)

      expect(stdout_output).to include('Duration: 1s')
    end

    it 'shows URLs/min rate' do
      results = [WaybackArchiver::ArchiveResult.new('http://a.com', timestamp: '20240101000000')]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 120.0
      cli = build_cli('http://example.com')
      cli.send(:print_summary, results, start)

      expect(stdout_output).to include('URLs/min')
    end
  end

  describe '#install_signal_handler' do
    it 'does nothing without a session' do
      cli = build_cli('--no-session', 'http://example.com')
      cli.instance_variable_set(:@session, nil)

      expect(Signal).not_to receive(:trap)
      cli.send(:install_signal_handler)
    end
  end

  describe '#build_resume_command' do
    it 'includes --file when file_path was used' do
      cli = build_cli('--crawl', '--file=/tmp/urls.txt')
      cli.instance_variable_set(:@urls, ['http://example.com'])
      cli.instance_variable_set(:@strategy, 'crawl')
      cli.instance_variable_set(:@file_path, '/tmp/urls.txt')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')
      cli.instance_variable_set(:@session, session)

      cmd = cli.send(:build_resume_command)

      expect(cmd).to include('--file=/tmp/urls.txt')
      expect(cmd).not_to include('http://example.com')
    end

    it 'includes SPN2 options' do
      cli = build_cli('--urls', '--capture-all', 'http://example.com')
      cli.instance_variable_set(:@urls, ['http://example.com'])
      cli.instance_variable_set(:@strategy, 'urls')
      session = instance_double(WaybackArchiver::SessionFile, path: '/tmp/session.jsonl')
      cli.instance_variable_set(:@session, session)

      cmd = cli.send(:build_resume_command)

      expect(cmd).to include('--capture-all')
    end
  end

  describe WaybackArchiver::CLIListener do
    describe 'non-TTY mode' do
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

      describe '#on_progress' do
        it 'does not print anything' do
          listener.on_progress(captured: 5, failed: 0, pending: 3)
          expect(stdout_output).to eq('')
        end
      end

      describe '#on_waiting_for_slots' do
        it 'does not print anything' do
          listener.on_waiting_for_slots(processing: 7)
          expect(stdout_output).to eq('')
        end
      end
    end

    describe 'TTY mode' do
      let(:listener) { described_class.new(stdout, tty: true) }

      def clean_output
        stdout_output.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
      end

      it 'renders progress footer after on_batch_start' do
        listener.on_batch_start(total: 100)

        expect(clean_output).to include('0/100')
        expect(clean_output).to include('Submitting...')
      end

      it 'prints completed URL above footer' do
        listener.on_batch_start(total: 10)
        result = WaybackArchiver::ArchiveResult.new('http://example.com', timestamp: '20240101000000')
        listener.on_completed(result: result)

        expect(clean_output).to include('[1]')
        expect(clean_output).to include('http://example.com')
        expect(clean_output).to include('1/10')
      end

      it 'updates pending count on progress' do
        listener.on_batch_start(total: 10)
        listener.on_progress(captured: 2, failed: 0, pending: 5)

        expect(clean_output).to include('5 pending')
        expect(clean_output).to include('Polling...')
      end

      it 'shows waiting state' do
        listener.on_batch_start(total: 10)
        listener.on_waiting_for_slots(processing: 7)

        expect(clean_output).to include('Waiting for available slots...')
      end

      it 'clears footer on finish' do
        listener.on_batch_start(total: 10)
        listener.finish

        # After finish, the ANSI clear sequences should have been written
        expect(stdout_output).to include("\e[A")
      end
    end
  end
end
