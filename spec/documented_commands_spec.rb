require 'spec_helper'
require 'tmpdir'

# Smoke tests for every `wayback_archiver` command line printed in the README
# and in examples/*.sh. The commands are read out of those files and run
# against HTTP fixtures through the real CLI, so a documented flag that no
# longer exists, or a pipeline whose output cannot be fed back in, fails here
# instead of on a user's terminal.
RSpec.describe 'documented CLI commands' do
  include CLIHelper
  include DocumentedCommands
  include DocFixtures

  ROOT = File.expand_path('..', __dir__)

  before do
    allow(ENV).to receive(:[]).with('WAYBACK_ACCESS_KEY').and_return('test-ak')
    allow(ENV).to receive(:[]).with('WAYBACK_SECRET_KEY').and_return('test-sk')
    # The CLI sets credentials from its options, which rebuilds the capture
    # rate limiter — disable it at the source so a documented --concurrency=10
    # command does not wait out a real minute.
    allow(WaybackArchiver::RateLimiter).to receive(:for_current_user)
      .and_return(WaybackArchiver::RateLimiter.new(max_requests: 999, enabled: false))

    stub_documented_endpoints!
  end

  # Commands that archive: every other documented mode (discovery, checking,
  # status) deliberately submits nothing.
  NON_ARCHIVING = %w[--list-urls --check --status --skip-archived].freeze

  # Enumerated at load time so each documented command becomes its own example
  # with its own failure message.
  EXTRACTOR = Object.new.extend(DocumentedCommands)

  %w[README.md examples/file_input.sh examples/two_phase.sh].each do |relative_path|
    describe relative_path do
      commands = EXTRACTOR.documented_commands(File.join(ROOT, relative_path))

      it 'still documents runnable commands' do
        expect(commands).not_to be_empty
      end

      commands.each do |command|
        it "runs: #{command}" do
          Dir.mktmpdir do |dir|
            write_documented_inputs!(dir)
            stdout, stderr, status = run_documented_command(command, dir: dir)

            expect(status.code).to eq(0), "exited #{status.code}\nstdout: #{stdout}\nstderr: #{stderr}"
            expect(stderr).not_to match(/invalid option|Traceback|NoMethodError|undefined method/)

            # Exit 0 having quietly archived nothing is the failure mode these
            # commands are most likely to regress into.
            next if NON_ARCHIVING.any? { |flag| command.include?(flag) }

            expect(WebMock).to have_requested(:post, "#{DocFixtures::WAYBACK}/save").at_least_once
          end
        end
      end
    end
  end

  describe 'the two-phase pipeline' do
    it 'archives from a list the previous command produced' do
      Dir.mktmpdir do |dir|
        write_documented_inputs!(dir)
        File.delete(File.join(dir, 'urls.txt'))

        discover = 'wayback_archiver https://example.com --crawl --list-urls > urls.txt'
        _, _, status = run_documented_command(discover, dir: dir)
        expect(status.code).to eq(0)

        listed = File.read(File.join(dir, 'urls.txt')).lines.map(&:strip).reject(&:empty?)
        expect(listed).to all(match(%r{\Ahttps?://}))
        expect(listed).not_to be_empty

        stdout, stderr, status = run_documented_command('wayback_archiver --file=urls.txt --concurrency=2', dir: dir)

        expect(status.code).to eq(0), stderr
        expect(stdout).to include("#{listed.length} URL(s)").or include(listed.length.to_s)
      end
    end
  end

  describe 'the session/resume pair' do
    it 'resumes from the session the previous command wrote' do
      Dir.mktmpdir do |dir|
        write_documented_inputs!(dir)
        File.delete(File.join(dir, 'session.jsonl'))

        _, stderr, status = run_documented_command(
          'wayback_archiver https://example.com --urls --session=session.jsonl', dir: dir
        )
        expect(status.code).to eq(0), stderr
        expect(File.read(File.join(dir, 'session.jsonl'))).to include('https://example.com')

        stdout, stderr, status = run_documented_command(
          'wayback_archiver https://example.com --urls --resume=session.jsonl', dir: dir
        )

        expect(status.code).to eq(0), stderr
        expect(stdout + stderr).to match(/previously succeeded|already/i)
      end
    end
  end
end
