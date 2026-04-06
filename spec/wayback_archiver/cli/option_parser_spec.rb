require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'wayback_archiver/cli/option_parser'

RSpec.describe WaybackArchiver::CLI::OptionParser do
  let(:stdout) { StringIO.new }

  def parse(*args)
    described_class.new(args, stdout: stdout).parse!
  end

  describe 'strategy parsing' do
    it 'parses --auto' do
      expect(parse('--auto', 'http://example.com').strategy).to eq('auto')
    end

    it 'parses --crawl' do
      expect(parse('--crawl', 'http://example.com').strategy).to eq('crawl')
    end

    it 'parses --sitemap' do
      expect(parse('--sitemap', 'http://example.com').strategy).to eq('sitemap')
    end

    it 'parses --urls' do
      expect(parse('--urls', 'http://example.com').strategy).to eq('urls')
    end

    it 'parses --rss' do
      expect(parse('--rss', 'http://example.com').strategy).to eq('rss')
    end
  end

  describe 'option parsing' do
    it 'parses --concurrency' do
      expect(parse('--concurrency=8', 'http://example.com').concurrency).to eq(8)
    end

    it 'parses --limit' do
      expect(parse('--limit=50', 'http://example.com').limit).to eq(50)
    end

    it 'parses --check' do
      expect(parse('--check', 'http://example.com').check_mode).to eq(true)
    end

    it 'parses --status' do
      opts = described_class.new(['--status'], stdout: stdout).parse!
      expect(opts.status_mode).to eq(true)
    end

    it 'parses --no-summary' do
      expect(parse('--no-summary', 'http://example.com').show_summary).to eq(false)
    end

    it 'parses --no-session' do
      expect(parse('--no-session', 'http://example.com').no_session).to eq(true)
    end

    it 'parses SPN2 capture options' do
      opts = parse('--capture-all', '--force-get', 'http://example.com')
      expect(opts.spn2_options[:capture_all]).to eq(true)
      expect(opts.spn2_options[:force_get]).to eq(true)
    end

    it 'parses --report' do
      expect(parse('--report=/tmp/out.csv', 'http://example.com').report_path).to eq('/tmp/out.csv')
    end

    it 'parses --quiet to set FATAL log level' do
      expect(parse('--quiet', 'http://example.com').log_level).to eq(Logger::FATAL)
    end

    it 'parses --verbose to set DEBUG log level' do
      expect(parse('--verbose', 'http://example.com').log_level).to eq(Logger::DEBUG)
    end

    it 'parses --no-verbose to set WARN log level' do
      expect(parse('--no-verbose', 'http://example.com').log_level).to eq(Logger::WARN)
    end

    it 'rejects --concurrency=0' do
      expect { parse('--concurrency=0', 'http://example.com') }
        .to raise_error(ArgumentError, /Concurrency/)
    end

    it 'rejects --limit=0' do
      expect { parse('--limit=0', 'http://example.com') }
        .to raise_error(ArgumentError, /Limit/)
    end

    it 'accepts --limit=-1 for unlimited' do
      expect(parse('--limit=-1', 'http://example.com').limit).to eq(-1)
    end

    it 'rejects --js-behavior-timeout=31' do
      expect { parse('--js-behavior-timeout=31', 'http://example.com') }
        .to raise_error(ArgumentError, /js-behavior-timeout/)
    end

    it 'rejects invalid --hosts regex' do
      expect { parse('--hosts=[invalid', 'http://example.com') }
        .to raise_error(ArgumentError, /Invalid host pattern/)
    end

    it 'parses --hosts as array of Regexp' do
      opts = parse('--hosts=example\\.com,other\\.org', 'http://example.com')
      expect(opts.hosts.length).to eq(2)
      expect(opts.hosts).to all(be_a(Regexp))
    end

    it 'parses --skip-archived without value' do
      opts = parse('--skip-archived', 'http://example.com')
      expect(opts.skip_archived).to eq(true)
      expect(opts.skip_archived_within).to be_nil
    end

    it 'parses --skip-archived with timedelta value' do
      opts = parse('--skip-archived=7d', 'http://example.com')
      expect(opts.skip_archived).to eq(true)
      expect(opts.skip_archived_within).to eq('7d')
    end
  end

  describe 'validation' do
    it 'rejects --check with --skip-archived' do
      expect { parse('--check', '--skip-archived', 'http://example.com') }
        .to raise_error(ArgumentError, /mutually exclusive/)
    end

    it 'rejects --resume with --session' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, 'session.jsonl')
        File.write(session, '')
        expect { parse('--resume', session, '--session', File.join(dir, 'other.jsonl'), 'http://example.com') }
          .to raise_error(ArgumentError, /mutually exclusive/)
      end
    end

    it 'rejects --resume with --no-session' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, 'session.jsonl')
        File.write(session, '')
        expect { parse('--resume', session, '--no-session', 'http://example.com') }
          .to raise_error(ArgumentError, /mutually exclusive/)
      end
    end

    it 'rejects --resume with nonexistent file' do
      expect { parse('--resume', '/tmp/nonexistent-session-file', 'http://example.com') }
        .to raise_error(ArgumentError, /not found/)
    end

    it 'requires at least one URL' do
      expect { parse('--urls') }
        .to raise_error(ArgumentError, /required/)
    end
  end

  describe 'URL reading' do
    it 'reads URLs from argv' do
      opts = parse('--urls', 'http://a.com', 'http://b.com')
      expect(opts.urls).to eq(%w[http://a.com http://b.com])
    end

    it 'reads URLs from --file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n# comment\n\nhttp://b.com\n")
        opts = parse('--file', path)
        expect(opts.urls).to eq(%w[http://a.com http://b.com])
      end
    end

    it 'defaults to --urls strategy when --file is used' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n")
        opts = parse('--file', path)
        expect(opts.strategy).to eq('urls')
      end
    end

    it 'deduplicates URLs from file and argv' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'urls.txt')
        File.write(path, "http://a.com\n")
        opts = parse('--file', path, 'http://a.com')
        expect(opts.urls).to eq(%w[http://a.com])
      end
    end

    it 'raises on missing file' do
      expect { parse('--file', '/nonexistent/urls.txt') }
        .to raise_error(ArgumentError, /File not found/)
    end
  end
end
