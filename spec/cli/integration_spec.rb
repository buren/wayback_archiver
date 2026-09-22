require 'spec_helper'
require 'open3'
require 'tmpdir'

# A small set of subprocess tests that verify the real binary works end-to-end.
# Most CLI tests run in-process (see cli_spec.rb and cli/**/*_spec.rb) for speed;
# these shell out to catch issues that only surface in a real process (load path,
# exit codes, signal handling, etc.).
RSpec.describe 'CLI integration', :integration do
  include SubprocessCLIHelper

  it '--help prints usage and exits 0' do
    stdout, _stderr, status = run_cli_subprocess('--help')

    expect(status).to be_success
    expect(stdout).to include('Usage: wayback_archiver')
  end

  it '--version prints version and exits 0' do
    stdout, _stderr, status = run_cli_subprocess('--version')

    expect(status).to be_success
    expect(stdout).to match(/WaybackArchiver version \d+/)
  end

  it 'exits non-zero with no arguments' do
    _stdout, stderr, status = run_cli_subprocess

    expect(status).not_to be_success
    expect(stderr).to include('required')
  end

  it 'rejects unknown flags' do
    _stdout, stderr, status = run_cli_subprocess('--bogus-flag')

    expect(status).not_to be_success
    expect(stderr).to include('invalid option')
  end

  it 'reports user errors cleanly without a Ruby backtrace' do
    _stdout, stderr, status = run_cli_subprocess('--bogus-flag')

    expect(status.exitstatus).to eq(2)
    expect(stderr).to start_with('wayback_archiver:')
    expect(stderr).not_to match(/\.rb:\d+:in/) # no backtrace frames
  end

  it 'reports validation errors for mutually exclusive flags' do
    _stdout, stderr, status = run_cli_subprocess('--check', '--skip-archived', 'http://example.com')

    expect(status).not_to be_success
    expect(stderr).to include('mutually exclusive')
  end

  it 'reads URLs from a file via --file' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'urls.txt')
      File.write(path, "https://example.com\n")

      _stdout, stderr, _status = run_cli_subprocess('--file', path, '--urls')

      expect(stderr).not_to include('File not found')
      expect(stderr).not_to include('[<url>] or --file is required')
    end
  end

  it 'prints the resume command and exits 130 on SIGINT' do
    Dir.mktmpdir do |dir|
      session_path = File.join(dir, 'session.jsonl')
      lib_path = File.expand_path('../../lib', __dir__)
      # Hermetic child: WaybackMachine is stubbed so no network happens, and
      # the in-flight submit sleeps so SIGINT lands mid-archive (after the
      # trap is installed). The MARKER line tells the parent when to signal.
      script = <<~RUBY
        $LOAD_PATH.unshift(#{lib_path.inspect})
        require 'wayback_archiver/cli'

        class WaybackArchiver::WaybackMachine
          def self.check_user_status
            { 'available' => 1, 'processing' => 0 }
          end

          def self.submit(_url, **)
            puts 'MARKER_SUBMITTING'
            $stdout.flush
            sleep 60
            {}
          end
        end

        WaybackArchiver::CLI.run(
          ['--urls', '--no-summary', '--session=#{session_path}', 'http://example.com']
        )
      RUBY

      env = { 'WAYBACK_ACCESS_KEY' => 'test', 'WAYBACK_SECRET_KEY' => 'test' }
      Open3.popen3(env, RbConfig.ruby, '-e', script) do |_stdin, out, err, wait_thr|
        buffer = +''
        deadline = Time.now + 15
        until buffer.include?('MARKER_SUBMITTING')
          raise "child never reached submit; output so far: #{buffer.inspect}" if Time.now > deadline

          begin
            buffer << out.read_nonblock(4096)
          rescue IO::WaitReadable
            sleep 0.05
          rescue EOFError
            raise "child exited early; output: #{buffer.inspect}, stderr: #{err.read.inspect}"
          end
        end

        Process.kill('INT', wait_thr.pid)
        status = wait_thr.value
        stderr_out = err.read

        expect(status.exitstatus).to eq(130)
        expect(stderr_out).to include('Resume with:')
        expect(stderr_out).to include(session_path)
      end
    end
  end
end
