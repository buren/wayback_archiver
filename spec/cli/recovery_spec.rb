require 'spec_helper'
require 'tmpdir'

RSpec.describe 'CLI recovery of accepted jobs' do
  include CLIHelper

  let(:machine) { WaybackArchiver::WaybackMachine }
  let(:url) { 'https://example.com/' }

  around do |example|
    Dir.mktmpdir('wayback-recovery-spec-') do |dir|
      @dir = dir
      @session_path = File.join(dir, 'session.jsonl')
      example.run
    end
  end

  before do
    WaybackArchiver.config.access_key = 'test-access'
    WaybackArchiver.config.secret_key = 'test-secret'
    allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
    stub_request(:get, %r{web\.archive\.org/save/status/user})
      .to_return(body: JSON.generate(available: 2, processing: 0))
    # A job whose status SPN2 has forgotten is now resolved against the
    # Wayback Machine. Default to "no capture found" so these examples keep
    # exercising the unresolved path they were written for; the examples that
    # care about the resolution itself override this.
    stub_request(:get, %r{web\.archive\.org/cdx/search/cdx}).to_return(body: '[]')
  end

  def save_pending(entries = { url => 'saved-job' })
    session = WaybackArchiver::SessionFile.new(@session_path)
    entries.each do |uri, job_id|
      session.write_result(WaybackArchiver::ArchiveResult.new(uri, job_id: job_id, status_ext: 'submitted'))
    end
    session.close
  end

  def stub_poll(response)
    stub_request(:post, machine::STATUS_URL).to_return(body: JSON.generate(response))
  end

  def records
    File.readlines(@session_path).map { |line| JSON.parse(line) }
  end

  [1, 4].each do |concurrency|
    it "recovers several jobs in one request without resubmitting (concurrency #{concurrency})" do
      other = 'https://example.com/other'
      save_pending(url => 'first', other => 'second')
      stub_poll('first' => { status: 'success', timestamp: '20260921100000' },
                'second' => { status: 'success', timestamp: '20260921100001' })
      report = File.join(@dir, 'report.json')
      expect(machine.rate_limiter).not_to receive(:acquire)

      stdout, stderr, status = run_cli(url, other, '--urls', "--resume=#{@session_path}",
                                      "--report=#{report}", "--concurrency=#{concurrency}")

      expect(status.code).to eq(0), stderr
      expect(stdout).to include('Succeeded: 2')
      expect(WebMock).to have_requested(:post, machine::STATUS_URL)
        .with(body: { 'job_ids' => 'first,second' }).once
      expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
      expect(records.last(2).map { |record| record['success'] }).to eq([true, true])
      expect(JSON.parse(File.read(report)).map { |record| record['job_id'] }).to eq(%w[first second])
    end
  end

  it 'polls an existing pending job until it succeeds' do
    save_pending
    stub_request(:post, machine::STATUS_URL).to_return(
      { body: JSON.generate('saved-job' => { status: 'pending' }) },
      { body: JSON.generate('saved-job' => { status: 'success', timestamp: '20260921100000' }) }
    )

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(WebMock).to have_requested(:post, machine::STATUS_URL).twice
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
    expect(records.last['success']).to eq(true)
  end

  it 'reports a permanent failure without submitting it again in the same run' do
    save_pending
    stub_poll('saved-job' => { status: 'error', status_ext: 'error:blocked-url', message: 'Blocked' })

    stdout, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(stdout).to include('Failed: 1')
    expect(records.last['status_ext']).to eq('error:blocked-url')
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'never turns a bare remote error status into a successful recovered capture' do
    save_pending
    stub_poll('saved-job' => { status: 'error' })

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(records.last['success']).to eq(false)
    expect(records.last['status_ext']).to eq('error:unknown')
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'recovers jobs even when their URLs have disappeared from the source sitemap' do
    save_pending
    source = 'https://example.com/sitemap.xml'
    new_url = 'https://example.com/new'
    stub_request(:get, source).to_return(body: "<urlset><url><loc>#{new_url}</loc></url></urlset>")
    stub_poll('saved-job' => { status: 'success', timestamp: '20260921100000' })
    stub_request(:post, machine::SAVE_URL).with(body: hash_including('url' => new_url))
      .to_return(body: JSON.generate(timestamp: '20260921100001'))

    stdout, stderr, status = run_cli(source, '--sitemap', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(stdout).to include('Succeeded: 1', 'Cached: 1')
    expect(records.select { |record| record['success'] }.map { |record| record['url'] })
      .to contain_exactly(url, new_url)
    expect(WebMock).to have_requested(:post, machine::SAVE_URL).once
  end

  it 'checks saved jobs directly without spending CDX requests when --skip-archived is enabled' do
    save_pending
    stub_poll('saved-job' => { status: 'success', timestamp: '20260921100000' })
    expect(WaybackArchiver::CDX).not_to receive(:check)

    _, stderr, status = run_cli(url, '--urls', '--skip-archived', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(records.last['success']).to eq(true)
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'retries a confirmed transient failure with a new capture, then persists the result' do
    save_pending
    stub_request(:post, machine::STATUS_URL).to_return(
      { body: JSON.generate('saved-job' => { status: 'error', status_ext: 'error:service-unavailable' }) },
      { body: JSON.generate('new-job' => { status: 'success', timestamp: '20260921100000' }) }
    )
    stub_request(:post, machine::SAVE_URL).with(body: hash_including('url' => url))
      .to_return(body: JSON.generate(job_id: 'new-job'))

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(WebMock).to have_requested(:post, machine::SAVE_URL).once
    expect(records.last['job_id']).to eq('new-job')
    expect(records.last['success']).to eq(true)
  end

  it 'bounds retries of repeatedly failing recovered captures' do
    save_pending
    stub_const('WaybackArchiver::BatchSubmitter::MAX_RETRIES', 2)
    stub_poll('saved-job' => { status: 'error', status_ext: 'error:service-unavailable' })
    stub_request(:post, machine::SAVE_URL).to_return(body: JSON.generate(job_id: 'saved-job'))

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(WebMock).to have_requested(:post, machine::SAVE_URL).twice
    expect(records.last['status_ext']).to eq('error:service-unavailable')
  end

  it 'retries a failed status read without submitting a new capture' do
    save_pending
    stub_request(:post, machine::STATUS_URL).to_return(
      { status: 503, body: 'unavailable' },
      { body: JSON.generate('saved-job' => { status: 'success', timestamp: '20260921100000' }) }
    )

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(WebMock).to have_requested(:post, machine::STATUS_URL).twice
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'handles the supported array response including empty entries' do
    save_pending
    stub_poll([nil, { job_id: 'saved-job', status: 'success', timestamp: '20260921100000' }])

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(records.last['success']).to eq(true)
  end

  it 'retains unresolved jobs and polls only the remaining pending IDs in a mixed array response' do
    other = 'https://example.com/other'
    missing = 'https://example.com/unknown'
    save_pending(url => 'finished', other => 'waiting', missing => 'missing')
    stub_request(:post, machine::STATUS_URL).to_return(
      { body: JSON.generate([nil, { job_id: 'finished', status: 'success', timestamp: '20260921100000' },
                             { job_id: 'waiting', status: 'pending' }]) },
      { body: JSON.generate([{ job_id: 'waiting', status: 'success', timestamp: '20260921100001' }]) }
    )

    stdout, stderr, status = run_cli(url, other, missing, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(stdout).to include('Succeeded: 2', 'Incomplete: 1')
    expect(WebMock).to have_requested(:post, machine::STATUS_URL).with(body: { 'job_ids' => 'waiting' }).once
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
    session = WaybackArchiver::SessionFile.new(@session_path)
    expect(session.pending_jobs.transform_values { |job| job[:job_id] }).to eq(missing => 'missing')
    expect(session.completed_urls).to eq(Set[url, other])
    session.close
  end

  it 'does not count recovered jobs against the limit for new URLs' do
    save_pending
    fresh = 'https://example.com/new'
    stub_poll('saved-job' => { status: 'success', timestamp: '20260921100000' })
    stub_request(:post, machine::SAVE_URL).with(body: hash_including('url' => fresh))
      .to_return(body: JSON.generate(timestamp: '20260921100001'))

    _, stderr, status = run_cli(url, fresh, 'https://example.com/excess', '--urls', '--limit=1',
                               "--resume=#{@session_path}")

    expect(status.code).to eq(0), stderr
    expect(WebMock).to have_requested(:post, machine::SAVE_URL).once
    expect(records.select { |record| record['success'] }.map { |record| record['url'] })
      .to contain_exactly(url, fresh)
  end

  [{}, { 'saved-job' => nil }].each do |response|
    it "preserves missing or expired status as incomplete without resubmission (#{response.inspect})" do
      save_pending
      stub_poll(response)
      report = File.join(@dir, 'report.json')

      stdout, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}", "--report=#{report}")

      expect(status.code).to eq(1), stderr
      expect(stdout).to include('Incomplete: 1')
      expect(stdout).to include('possibly expired')
      expect(stderr).to include('Resume with:')
      expect(WebMock).to have_requested(:post, machine::STATUS_URL).once
      expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
      expect(records.last['job_id']).to eq('saved-job')
      expect(records.last['success']).to eq(false)
      expect(records.last['status_ext']).to eq('incomplete:status-unavailable')
      expect(JSON.parse(File.read(report)).last['status_ext']).to eq('incomplete:status-unavailable')
    end
  end

  it 'retains a submitted record without a job ID instead of silently submitting it again' do
    save_pending(url => nil)

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(records.last['status_ext']).to eq('incomplete:missing-job-id')
    expect(WebMock).not_to have_requested(:post, machine::STATUS_URL)
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  %w[json csv jsonl].each do |format|
    it "retains an automatic session and a final #{format} record on timeout, then recovers on resume" do
      allow(WaybackArchiver::SessionFile).to receive(:auto_path).and_return(@session_path)
      stub_const('WaybackArchiver::WaybackMachine::POLL_TIMEOUT', -1)
      stub_request(:post, machine::SAVE_URL).to_return(body: JSON.generate(job_id: 'saved-job'))
      poll = stub_poll('saved-job' => { status: 'pending' })
      report = File.join(@dir, "report.#{format}")

      stdout, stderr, status = run_cli(url, '--urls', "--report=#{report}")

      expect(status.code).to eq(1), stderr
      expect(stdout).to include('Succeeded: 0', 'Incomplete: 1')
      expect(stderr).to include('Resume with:')
      expect(File).to exist(@session_path)
      expect(records.last['status_ext']).to eq('incomplete:poll-timeout')
      report_records = case format
                       when 'json' then JSON.parse(File.read(report))
                       when 'csv' then CSV.read(report, headers: true).map(&:to_h)
                       else File.readlines(report).map { |line| JSON.parse(line) }
                       end
      expect(report_records.length).to eq(1)
      expect(report_records.first['job_id']).to eq('saved-job')
      expect(report_records.first['status_ext']).to eq('incomplete:poll-timeout')

      remove_request_stub(poll)
      stub_poll('saved-job' => { status: 'success', timestamp: '20260921100000' })
      _, stderr, resumed = run_cli(url, '--urls', "--resume=#{@session_path}", "--report=#{report}")

      expect(resumed.code).to eq(0), stderr
      expect(records.last['success']).to eq(true)
      expect(WebMock).to have_requested(:post, machine::SAVE_URL).once
    end
  end

  it 'backs off failed status reads and preserves the job if the polling deadline expires' do
    save_pending
    stub_const('WaybackArchiver::WaybackMachine::POLL_TIMEOUT', 25)
    stub_request(:post, machine::STATUS_URL).to_return(status: 429, body: 'throttled')
    clock = 100.0
    waits = []
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock }
    allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep) do |_, seconds|
      waits << seconds
      clock += seconds
    end

    _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")

    expect(status.code).to eq(1), stderr
    expect(waits.length).to be <= 4
    expect(waits[1]).to be > waits[0]
    expect(clock).to eq(125.0)
    expect(WebMock).to have_requested(:post, machine::STATUS_URL).times(3)
    expect(records.last['status_ext']).to eq('incomplete:poll-timeout')
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'can resume an unavailable job repeatedly without losing or duplicating it' do
    save_pending
    stub_poll('saved-job' => nil)

    2.times do
      _, stderr, status = run_cli(url, '--urls', "--resume=#{@session_path}")
      expect(status.code).to eq(1), stderr
    end

    expect(records.last['job_id']).to eq('saved-job')
    expect(records.last['status_ext']).to eq('incomplete:status-unavailable')
    expect(WebMock).to have_requested(:post, machine::STATUS_URL).twice
    expect(WebMock).not_to have_requested(:post, machine::SAVE_URL)
  end

  it 'reports an incomplete run even when session persistence is disabled' do
    stub_const('WaybackArchiver::WaybackMachine::POLL_TIMEOUT', -1)
    stub_request(:post, machine::SAVE_URL).to_return(body: JSON.generate(job_id: 'saved-job'))
    stub_poll('saved-job' => { status: 'pending' })
    report = File.join(@dir, 'report.json')

    stdout, stderr, status = run_cli(url, '--urls', '--no-session', "--report=#{report}")

    expect(status.code).to eq(1), stderr
    expect(stdout).to include('Incomplete: 1')
    expect(stderr).not_to include('Resume with:')
    expect(JSON.parse(File.read(report)).first['status_ext']).to eq('incomplete:poll-timeout')
    expect(File).not_to exist(@session_path)
  end

  describe 'resolving jobs whose status has expired' do
    # SPN2 keeps job status for about an hour. Past that a recovered job used
    # to sit in permanent limbo: polled, found missing, recorded incomplete,
    # written back as pending, and re-polled on every future resume — exiting
    # 1 forever with no way out. The Wayback Machine is the durable record of
    # whether the capture landed, so ask it instead.
    before do
      allow_any_instance_of(WaybackArchiver::BatchSubmitter).to receive(:sleep)
      allow(WaybackArchiver::WaybackMachine).to receive(:check_user_status)
        .and_return({ 'available' => 6, 'processing' => 0 })
      allow(WaybackArchiver::WaybackMachine).to receive(:poll_statuses).and_return({})
    end

    def recover(since:, cdx:)
      allow(WaybackArchiver::CDX).to receive(:check).and_return(cdx)
      WaybackArchiver::BatchSubmitter.new(
        [], concurrency: 1,
        pending_jobs: { 'http://e.com/a' => { job_id: 'job-1', since: since } }
      ).call.first
    end

    let(:long_ago) { (Time.now.utc - 7200).iso8601 }
    let(:just_now) { (Time.now.utc - 60).iso8601 }

    it 'resolves as a success when the capture is in the Wayback Machine' do
      result = recover(
        since: long_ago,
        cdx: WaybackArchiver::CheckResult.new('http://e.com/a', archived: true, timestamp: '20260921120000')
      )

      expect(result).to be_success
      expect(result).to be_recovered
      expect(result.timestamp).to eq('20260921120000')
      expect(result.wayback_url).to include('20260921120000')
    end

    it 'searches from the submission time so an older capture is not mistaken for this job' do
      allow(WaybackArchiver::CDX).to receive(:check)
        .and_return(WaybackArchiver::CheckResult.new('http://e.com/a', archived: false))

      recover(since: long_ago, cdx: WaybackArchiver::CheckResult.new('http://e.com/a', archived: false))

      expect(WaybackArchiver::CDX).to have_received(:check)
        .with('http://e.com/a', from: Time.iso8601(long_ago).strftime('%Y%m%d%H%M%S'))
    end

    it 'fails the URL, making it resubmittable, when nothing was captured and the index has had time' do
      result = recover(since: long_ago, cdx: WaybackArchiver::CheckResult.new('http://e.com/a', archived: false))

      expect(result).to be_errored
      expect(result).not_to be_incomplete
      # Neither a success nor pending, so the next run discovers and submits it.
      expect(result.status_ext).to be_nil
    end

    it 'keeps it pending when the submission is too recent for CDX to have indexed' do
      result = recover(since: just_now, cdx: WaybackArchiver::CheckResult.new('http://e.com/a', archived: false))

      expect(result).to be_incomplete
      expect(result.status_ext).to eq('incomplete:status-unavailable')
    end

    it 'keeps it pending when the CDX lookup itself fails' do
      failed = WaybackArchiver::CheckResult.new(
        'http://e.com/a', archived: false, error: WaybackArchiver::Request::ServerError.new('503')
      )

      expect(recover(since: long_ago, cdx: failed)).to be_incomplete
    end

    it 'still resolves sessions written before submission times were recorded' do
      result = recover(
        since: nil,
        cdx: WaybackArchiver::CheckResult.new('http://e.com/a', archived: true, timestamp: '20260921120000')
      )

      expect(result).to be_success
      expect(WaybackArchiver::CDX).to have_received(:check).with('http://e.com/a', from: nil)
    end
  end
end
