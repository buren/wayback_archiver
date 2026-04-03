require 'spec_helper'

RSpec.describe 'CLI' do
  include CLIHelper

  def help_output
    @help_output ||= run_cli('--help').first
  end

  describe '--help' do
    it 'exits successfully' do
      _stdout, _stderr, status = run_cli('--help')
      expect(status.success?).to eq(true)
    end

    it 'shows usage banner' do
      expect(help_output).to include('Usage: wayback_archiver')
    end
  end

  describe '--version' do
    it 'prints version and exits successfully' do
      stdout, _stderr, status = run_cli('--version')
      expect(status.success?).to eq(true)
      expect(stdout).to match(/WaybackArchiver version \d+/)
    end
  end

  describe 'no arguments' do
    it 'exits with error' do
      _stdout, stderr, status = run_cli
      expect(status.success?).to eq(false)
      expect(stderr).to include('required')
    end
  end

  describe 'SPN2 capture flags' do
    %w[
      --capture-all
      --capture-outlinks
      --capture-screenshot
      --screenshot-dir=PATH
      --force-get
      --skip-first-archive
      --delay-wb-availability
      --if-not-archived-within=TIMEDELTA
      --js-behavior-timeout=N
      --use-user-agent=AGENT
      --outlinks-availability
    ].each do |flag|
      name = flag.split('=').first

      it "recognizes #{name}" do
        _stdout, stderr, _status = run_cli(name, '--help')
        expect(stderr).not_to include('invalid option')
      end

      it "shows #{name} in help output" do
        expect(help_output).to include(name)
      end
    end
  end

  describe '--js-behavior-timeout' do
    it 'rejects values above 30' do
      _stdout, stderr, status = run_cli('--js-behavior-timeout=31', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('js-behavior-timeout')
    end

    it 'rejects negative values' do
      _stdout, stderr, status = run_cli('--js-behavior-timeout=-1', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('js-behavior-timeout')
    end

    it 'accepts value within range' do
      _stdout, stderr, _status = run_cli('--js-behavior-timeout=15', '--help')
      expect(stderr).not_to include('js-behavior-timeout')
    end

    it 'accepts 0 to skip JS behaviors' do
      _stdout, stderr, _status = run_cli('--js-behavior-timeout=0', '--help')
      expect(stderr).not_to include('js-behavior-timeout')
    end
  end

  describe '--concurrency' do
    it 'rejects 0' do
      _stdout, stderr, status = run_cli('--concurrency=0', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('Concurrency')
    end

    it 'rejects negative values' do
      _stdout, stderr, status = run_cli('--concurrency=-1', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('Concurrency')
    end
  end

  describe 'mutually exclusive flags' do
    it 'rejects --check with --skip-archived' do
      _stdout, stderr, status = run_cli('--check', '--skip-archived', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('mutually exclusive')
    end

    it 'rejects --resume with --session' do
      _stdout, stderr, status = run_cli('--resume=/tmp/x', '--session=/tmp/y', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('mutually exclusive')
    end

    it 'rejects --resume with --no-session' do
      _stdout, stderr, status = run_cli('--resume=/tmp/x', '--no-session', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('mutually exclusive')
    end
  end

  describe '--resume' do
    it 'rejects non-existent session file' do
      _stdout, stderr, status = run_cli('--resume=/tmp/nonexistent-session-file', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('not found')
    end
  end

  describe 'unknown flags' do
    it 'rejects unrecognized options' do
      _stdout, stderr, status = run_cli('--bogus-flag', 'http://example.com')
      expect(status.success?).to eq(false)
      expect(stderr).to include('invalid option')
    end
  end

  describe 'additional CLI flags' do
    %w[
      --skip-archived
      --skip-archived=3d
      --report=PATH
      --quiet
    ].each do |flag|
      name = flag.split('=').first

      it "recognizes #{name}" do
        _stdout, stderr, _status = run_cli(name, '--help')
        expect(stderr).not_to include('invalid option')
      end

      it "shows #{name} in help output" do
        expect(help_output).to include(name)
      end
    end

    %w[--summary --no-summary].each do |flag|
      it "recognizes #{flag}" do
        _stdout, stderr, _status = run_cli(flag, '--help')
        expect(stderr).not_to include('invalid option')
      end
    end

    it 'shows --[no-]summary in help output' do
      expect(help_output).to include('--[no-]summary')
    end

    it 'recognizes -q shorthand for --quiet' do
      _stdout, stderr, _status = run_cli('-q', '--help')
      expect(stderr).not_to include('invalid option')
    end
  end
end
