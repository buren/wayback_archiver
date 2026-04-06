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

      cli.run

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
        ['http://example.com'],
        hash_including(
          strategy: 'urls',
          capture_all: true,
          force_get: true
        )
      )
    end

    it 'passes all urls in one call for urls strategy' do
      cli = build_cli('--urls', '--no-session', '--no-summary', 'http://a.com', 'http://b.com', 'http://c.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      cli.run

      expect(WaybackArchiver).to have_received(:archive).once.with(
        ['http://a.com', 'http://b.com', 'http://c.com'],
        hash_including(strategy: 'urls')
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

  describe WaybackArchiver::CLI::FooterAwareOutput do
    let(:io) { StringIO.new }
    let(:output) { described_class.new(io) }

    it 'writes directly to IO when no renderer is set' do
      output.write("hello\n")
      expect(io.string).to eq("hello\n")
    end

    it 'routes through renderer when one is set' do
      renderer = instance_double(WaybackArchiver::CLI::ProgressRenderer)
      expect(renderer).to receive(:print_above).with("WARN: error\n")

      output.renderer = renderer
      output.write("WARN: error\n")
    end

    it 'reverts to direct IO when renderer is cleared' do
      renderer = instance_double(WaybackArchiver::CLI::ProgressRenderer)
      output.renderer = renderer
      output.renderer = nil
      output.write("direct\n")

      expect(io.string).to eq("direct\n")
    end
  end

  describe '#install_signal_handler' do
    it 'does nothing without a session' do
      cli = build_cli('--no-session', '--no-summary', '--urls', 'http://example.com')
      allow(WaybackArchiver).to receive(:archive).and_return([])

      expect(Signal).not_to receive(:trap)
      cli.run
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

        expect(stdout_output).to include("\e[A")
      end
    end
  end
end
