require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'CLI --check flag' do
  let(:bin) { File.expand_path('../../bin/wayback_archiver', __dir__) }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def run_cli(*args, stdin_data: nil)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, bin, *args, stdin_data: stdin_data)
    [stdout, stderr, status]
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
