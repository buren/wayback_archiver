require 'stringio'
require 'wayback_archiver/cli'

# In-process CLI helper — calls CLI.run directly, no subprocess.
# Handles SystemExit (--help, --version, --check, --status) and
# ArgumentError / OptionParser errors the same way Ruby's default
# exception handler would in a real process.
module CLIHelper
  ExitStatus = Struct.new(:code) do
    def success?
      code == 0
    end
  end

  def run_cli(*args, stdin_data: nil)
    stdout = StringIO.new
    stderr = StringIO.new
    exit_code = 0

    original_stdin = $stdin
    $stdin = StringIO.new(stdin_data) if stdin_data

    begin
      WaybackArchiver::CLI.run(args, stdout: stdout, stderr: stderr)
    rescue SystemExit => e
      exit_code = e.status
    rescue ArgumentError, ::OptionParser::InvalidOption, ::OptionParser::InvalidArgument => e
      stderr.puts e.message
      exit_code = 1
    rescue => e
      # Non-parsing errors (auth, network, etc.) — mirrors subprocess behavior
      stderr.puts "#{e.class}: #{e.message}"
      exit_code = 1
    ensure
      $stdin = original_stdin
    end

    [stdout.string, stderr.string, ExitStatus.new(exit_code)]
  end
end

# Subprocess CLI helper — shells out to the real binary.
# Used only for a small number of integration tests.
module SubprocessCLIHelper
  require 'open3'

  # Credential env vars are explicitly unset (nil) so subprocess tests can
  # never hit the live SPN2 API on a machine with real keys exported — the
  # in-process ENV stubbing in spec_helper does not apply to child processes.
  BLANK_CREDENTIALS = {
    'WAYBACK_ACCESS_KEY' => nil,
    'WAYBACK_SECRET_KEY' => nil,
    'IA_S3_ACCESS_KEY' => nil,
    'IA_S3_SECRET_KEY' => nil
  }.freeze

  def run_cli_subprocess(*args, stdin_data: nil, env: {})
    bin = File.expand_path('../../bin/wayback_archiver', __dir__)
    Open3.capture3(BLANK_CREDENTIALS.merge(env), RbConfig.ruby, bin, *args, stdin_data: stdin_data)
  end
end
