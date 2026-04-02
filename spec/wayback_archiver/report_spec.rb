require 'spec_helper'
require 'wayback_archiver/report'
require 'csv'
require 'json'
require 'tmpdir'

RSpec.describe WaybackArchiver::Report do
  let(:success_result) do
    WaybackArchiver::ArchiveResult.new(
      'http://example.com',
      job_id: 'spn2-abc123',
      timestamp: '20260326120000',
      duration_sec: 3.5,
      screenshot_url: 'http://web.archive.org/screenshot/http://example.com/',
      original_url: 'http://example.com/'
    )
  end

  let(:error_result) do
    WaybackArchiver::ArchiveResult.new(
      'http://example.com/broken',
      error: RuntimeError.new('connection failed'),
      status_ext: 'error:cannot-fetch'
    )
  end

  let(:results) { [success_result, error_result] }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  describe '.write' do
    context 'with .csv extension' do
      it 'writes a valid CSV with header and rows' do
        path = File.join(@tmpdir, 'report.csv')
        described_class.write(results, path)

        csv = CSV.read(path)
        expect(csv.length).to eq(3) # header + 2 rows
        expect(csv[0]).to eq(described_class::COLUMNS)
      end

      it 'writes correct values for a success result' do
        path = File.join(@tmpdir, 'report.csv')
        described_class.write([success_result], path)

        row = CSV.read(path)[1]
        expect(row[0]).to eq('http://example.com')
        expect(row[1]).to eq('true')
        expect(row[2]).to eq('https://web.archive.org/web/20260326120000/http://example.com/')
        expect(row[3]).to eq('spn2-abc123')
        expect(row[4]).to eq('20260326120000')
        expect(row[5]).to eq('3.5')
        expect(row[6]).to eq('http://web.archive.org/screenshot/http://example.com/')
      end

      it 'writes correct values for an error result' do
        path = File.join(@tmpdir, 'report.csv')
        described_class.write([error_result], path)

        row = CSV.read(path)[1]
        expect(row[0]).to eq('http://example.com/broken')
        expect(row[1]).to eq('false')
        expect(row[2]).to be_nil
        expect(row[7]).to eq('error:cannot-fetch')
        expect(row[8]).to eq('transient')
        expect(row[9]).to eq('connection failed')
      end
    end

    context 'with .json extension' do
      it 'writes a valid JSON array' do
        path = File.join(@tmpdir, 'report.json')
        described_class.write(results, path)

        data = JSON.parse(File.read(path))
        expect(data).to be_an(Array)
        expect(data.length).to eq(2)
      end

      it 'writes correct values for a success result' do
        path = File.join(@tmpdir, 'report.json')
        described_class.write([success_result], path)

        entry = JSON.parse(File.read(path)).first
        expect(entry['url']).to eq('http://example.com')
        expect(entry['success']).to eq(true)
        expect(entry['wayback_url']).to eq('https://web.archive.org/web/20260326120000/http://example.com/')
        expect(entry['job_id']).to eq('spn2-abc123')
        expect(entry['timestamp']).to eq('20260326120000')
        expect(entry['duration_sec']).to eq(3.5)
        expect(entry['screenshot_url']).to eq('http://web.archive.org/screenshot/http://example.com/')
        expect(entry['error']).to be_nil
      end

      it 'writes correct values for an error result' do
        path = File.join(@tmpdir, 'report.json')
        described_class.write([error_result], path)

        entry = JSON.parse(File.read(path)).first
        expect(entry['url']).to eq('http://example.com/broken')
        expect(entry['success']).to eq(false)
        expect(entry['wayback_url']).to be_nil
        expect(entry['status_ext']).to eq('error:cannot-fetch')
        expect(entry['error_category']).to eq('transient')
        expect(entry['error']).to eq('connection failed')
      end
    end

    context 'with unsupported extension' do
      it 'raises ArgumentError' do
        path = File.join(@tmpdir, 'report.xml')
        expect { described_class.write(results, path) }
          .to raise_error(ArgumentError, /Unsupported report format/)
      end
    end

    context 'with CheckResult (check mode)' do
      let(:archived_check) do
        WaybackArchiver::CheckResult.new('http://example.com', archived: true, timestamp: '20260326120000')
      end

      let(:not_archived_check) do
        WaybackArchiver::CheckResult.new('http://other.com', archived: false)
      end

      it 'writes check CSV with correct columns' do
        path = File.join(@tmpdir, 'check.csv')
        described_class.write([archived_check, not_archived_check], path)

        csv = CSV.read(path)
        expect(csv[0]).to eq(described_class::CHECK_COLUMNS)
        expect(csv.length).to eq(3)
      end

      it 'writes correct check CSV values' do
        path = File.join(@tmpdir, 'check.csv')
        described_class.write([archived_check], path)

        row = CSV.read(path)[1]
        expect(row[0]).to eq('http://example.com')
        expect(row[1]).to eq('true')
        expect(row[2]).to eq('20260326120000')
        expect(row[3]).to eq('https://web.archive.org/web/20260326120000/http://example.com')
      end

      it 'writes correct check JSON values' do
        path = File.join(@tmpdir, 'check.json')
        described_class.write([archived_check, not_archived_check], path)

        data = JSON.parse(File.read(path))
        expect(data.length).to eq(2)

        expect(data[0]['url']).to eq('http://example.com')
        expect(data[0]['archived']).to eq(true)
        expect(data[0]['timestamp']).to eq('20260326120000')
        expect(data[0]['wayback_url']).to eq('https://web.archive.org/web/20260326120000/http://example.com')

        expect(data[1]['url']).to eq('http://other.com')
        expect(data[1]['archived']).to eq(false)
        expect(data[1]['timestamp']).to be_nil
      end
    end

    context 'with empty results' do
      it 'writes CSV with only a header' do
        path = File.join(@tmpdir, 'report.csv')
        described_class.write([], path)

        csv = CSV.read(path)
        expect(csv.length).to eq(1)
        expect(csv[0]).to eq(described_class::COLUMNS)
      end

      it 'writes an empty JSON array' do
        path = File.join(@tmpdir, 'report.json')
        described_class.write([], path)

        data = JSON.parse(File.read(path))
        expect(data).to eq([])
      end
    end
  end
end
