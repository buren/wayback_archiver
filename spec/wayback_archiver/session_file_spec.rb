require 'spec_helper'
require 'tmpdir'
require 'wayback_archiver/session_file'

RSpec.describe WaybackArchiver::SessionFile do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def session_path(name = 'test_session.jsonl')
    File.join(@tmpdir, name)
  end

  def make_result(url, success: true, job_id: nil, timestamp: nil, error: nil, status_ext: nil)
    WaybackArchiver::ArchiveResult.new(
      url,
      job_id: job_id,
      timestamp: timestamp,
      error: error,
      status_ext: status_ext
    )
  end

  describe '.auto_path' do
    it 'generates a path in the system temp directory with timestamp pattern' do
      path = described_class.auto_path
      expect(path).to start_with(Dir.tmpdir)
      expect(File.basename(path)).to match(/^wayback_archiver_\d{8}_\d{6}\.jsonl$/)
    end
  end

  describe '#write_result and #completed_urls' do
    it 'round-trips successful results' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://a.com', job_id: 'job-1', timestamp: '20260326120000'))
      session.write_result(make_result('http://b.com', job_id: 'job-2', timestamp: '20260326120001'))

      completed = session.completed_urls
      expect(completed).to include('http://a.com', 'http://b.com')

      session.close
    end

    it 'excludes failed results from completed_urls' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://ok.com'))
      session.write_result(make_result('http://fail.com', error: StandardError.new('boom')))

      completed = session.completed_urls
      expect(completed).to include('http://ok.com')
      expect(completed).not_to include('http://fail.com')

      session.close
    end

    it 'excludes results with error status_ext from completed_urls' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://fail.com', status_ext: 'error:invalid-host'))

      expect(session.completed_urls).not_to include('http://fail.com')

      session.close
    end

    it 'uses last-write-wins: failure then success means completed' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://a.com', error: StandardError.new('transient')))
      session.write_result(make_result('http://a.com', job_id: 'job-1', timestamp: '20260326'))

      expect(session.completed_urls).to include('http://a.com')

      session.close
    end

    it 'uses last-write-wins: success then failure means not completed' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://a.com', job_id: 'job-1', timestamp: '20260326'))
      session.write_result(make_result('http://a.com', error: StandardError.new('later failure')))

      expect(session.completed_urls).not_to include('http://a.com')

      session.close
    end
  end

  describe '#completed_urls when file does not exist' do
    it 'returns empty set when the file has been deleted' do
      path = File.join(@tmpdir, 'will_delete.jsonl')
      session = described_class.new(path)
      session.close

      # Remove the file so completed_urls hits Errno::ENOENT
      File.delete(path)

      expect(session.completed_urls).to eq(Set.new)
    end
  end

  describe '#completed_urls edge cases' do
    it 'returns empty set for empty file' do
      path = session_path
      session = described_class.new(path)

      expect(session.completed_urls).to eq(Set.new)

      session.close
    end

    it 'skips corrupt lines gracefully' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://ok.com'))
      session.close

      # Append a corrupt line
      File.open(path, 'a') { |f| f.puts('not valid json{{{') }

      session2 = described_class.new(path)
      expect(session2.completed_urls).to include('http://ok.com')

      session2.close
    end
  end

  describe '#write_result JSONL format' do
    it 'writes one valid JSON object per line' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://a.com', job_id: 'j1', timestamp: 't1'))
      session.write_result(make_result('http://b.com', error: StandardError.new('fail')))
      session.close

      lines = File.readlines(path)
      expect(lines.length).to eq(2)

      first = JSON.parse(lines[0])
      expect(first['url']).to eq('http://a.com')
      expect(first['success']).to eq(true)
      expect(first['job_id']).to eq('j1')
      expect(first['timestamp']).to eq('t1')
      expect(first['error']).to be_nil

      second = JSON.parse(lines[1])
      expect(second['url']).to eq('http://b.com')
      expect(second['success']).to eq(false)
      expect(second['error']).to eq('fail')
    end
  end

  describe 'thread safety' do
    it 'produces valid JSONL under concurrent writes' do
      path = session_path
      session = described_class.new(path)

      threads = 10.times.map do |i|
        Thread.new do
          5.times do |j|
            session.write_result(make_result("http://#{i}-#{j}.com"))
          end
        end
      end
      threads.each(&:join)
      session.close

      lines = File.readlines(path)
      expect(lines.length).to eq(50)
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end

  describe '#close' do
    it 'is idempotent' do
      session = described_class.new(session_path)
      session.close
      expect { session.close }.not_to raise_error
    end
  end

  describe '#delete!' do
    it 'removes the file from disk' do
      path = session_path
      session = described_class.new(path)
      session.write_result(make_result('http://a.com'))

      expect(File.exist?(path)).to eq(true)

      session.delete!

      expect(File.exist?(path)).to eq(false)
    end
  end
end
