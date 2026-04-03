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
      stdout, _stderr, _status = run_cli('--check', '--file', url_file, '--urls')

      expect(stdout).not_to include('Session file:')
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
