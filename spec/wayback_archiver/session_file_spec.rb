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
      # Timestamp plus a random suffix; see the collision example below.
      expect(File.basename(path)).to match(/^wayback_archiver_\d{8}_\d{6}_[0-9a-f]+\.jsonl$/)
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

    it 'keeps submitted jobs separate from completed URLs' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://submitted.com', job_id: 'job-1', status_ext: 'submitted'))

      expect(session.completed_urls).not_to include('http://submitted.com')
      expect(session.pending_jobs.transform_values { |j| j[:job_id] })
        .to eq('http://submitted.com' => 'job-1')

      session.close
    end

    it 'overwrites submitted with success on confirmed capture' do
      path = session_path
      session = described_class.new(path)

      session.write_result(make_result('http://a.com', job_id: 'job-1', status_ext: 'submitted'))
      session.write_result(make_result('http://a.com', job_id: 'job-1', timestamp: '20260326120000'))

      completed = session.completed_urls
      expect(completed).to include('http://a.com')
      expect(session.pending_jobs).to be_empty

      session.close
    end
  end

  describe '#pending_jobs' do
    it 'ignores corrupt records without losing the last valid job record' do
      session = described_class.new(session_path)
      session.write_result(make_result('http://a.com', job_id: 'job-1', status_ext: 'submitted'))
      session.close
      File.open(session_path, 'a') do |file|
        file.puts('null', '123', '[]', '{"url":null}', '{"url":""}', '{broken')
      end

      reopened = described_class.new(session_path)
      expect(reopened.completed_urls).to be_empty
      expect(reopened.pending_jobs.transform_values { |j| j[:job_id] }).to eq('http://a.com' => 'job-1')
      expect(WaybackArchiver.logger.warn_log).not_to be_empty
      reopened.close
    end

    it 'preserves incomplete jobs across close and reopen' do
      session = described_class.new(session_path)
      session.write_result(make_result('http://a.com', job_id: 'job-1', status_ext: 'incomplete:poll-timeout'))
      session.close

      reopened = described_class.new(session_path)
      expect(reopened.completed_urls).to be_empty
      expect(reopened.pending_jobs.transform_values { |j| j[:job_id] }).to eq('http://a.com' => 'job-1')
      reopened.close
    end

    it 'uses the latest job for each URL and removes jobs with a terminal failure' do
      session = described_class.new(session_path)
      session.write_result(make_result('http://a.com', job_id: 'old', status_ext: 'submitted'))
      session.write_result(make_result('http://a.com', job_id: 'new', status_ext: 'submitted'))
      session.write_result(make_result('http://b.com', job_id: 'failed', status_ext: 'submitted'))
      session.write_result(make_result('http://b.com', job_id: 'failed', status_ext: 'error:not-found'))

      expect(session.pending_jobs.transform_values { |j| j[:job_id] }).to eq('http://a.com' => 'new')
      expect(session.completed_urls).to be_empty
      session.close
    end

    it 'retains an unconfirmed URL even if its job ID is missing' do
      session = described_class.new(session_path)
      session.write_result(make_result('http://a.com', status_ext: 'submitted'))
      expect(session.pending_jobs.transform_values { |j| j[:job_id] }).to eq('http://a.com' => nil)
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

    it 'makes subsequent writes a safe no-op instead of raising IOError' do
      session = described_class.new(session_path)
      session.close
      expect { session.write_result(make_result('http://a.com')) }.not_to raise_error
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

  describe 'pending job timing' do
    # Resolving an expired job against CDX needs to know when it was
    # submitted: "no capture indexed yet" means nothing moments after
    # submission, and means the capture never happened an hour later.
    it 'records when each result was written' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'session.jsonl')
        session = described_class.new(path)
        session.write_result(
          WaybackArchiver::ArchiveResult.new('http://e.com/a', job_id: 'job-1', status_ext: 'submitted')
        )
        session.close

        record = JSON.parse(File.read(path).lines.first)
        expect(record['recorded_at']).to match(/\A\d{4}-\d{2}-\d{2}T/)
      end
    end

    it 'reports the job id and the time it first went pending' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'session.jsonl')
        session = described_class.new(path)
        submitted = WaybackArchiver::ArchiveResult.new('http://e.com/a', job_id: 'job-1', status_ext: 'submitted')
        session.write_result(submitted)
        # A later incomplete record must not reset the clock: the job was
        # submitted at the first timestamp, not when we gave up polling.
        sleep 0.01
        session.write_result(
          WaybackArchiver::ArchiveResult.new('http://e.com/a', job_id: 'job-1', status_ext: 'incomplete:poll-timeout')
        )
        session.close

        pending = described_class.new(path).pending_jobs
        first_line = JSON.parse(File.read(path).lines.first)

        expect(pending['http://e.com/a'][:job_id]).to eq('job-1')
        expect(pending['http://e.com/a'][:since]).to eq(first_line['recorded_at'])
      end
    end
  end

  describe '.auto_path' do
    # Regression: the name held only a second-resolution timestamp, so two
    # runs starting in the same second shared one append-only file with
    # independent mutexes — and either could delete the other's recovery data.
    it 'is unique for runs starting in the same second' do
      allow(Time).to receive(:now).and_return(Time.at(1_790_000_000))

      paths = 20.times.map { described_class.auto_path }

      expect(paths.uniq.length).to eq(20)
    end

    it 'still names the file by timestamp for recognisability' do
      allow(Time).to receive(:now).and_return(Time.at(1_790_000_000))

      expect(described_class.auto_path).to include(Time.at(1_790_000_000).strftime('%Y%m%d_%H%M%S'))
    end
  end
end
