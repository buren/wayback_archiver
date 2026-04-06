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
end
