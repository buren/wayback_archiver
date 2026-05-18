require 'spec_helper'
require 'wayback_archiver/report_writer'
require 'csv'
require 'json'
require 'tmpdir'

RSpec.describe WaybackArchiver::ReportWriter do
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

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  describe 'CSV format' do
    it 'writes header on construction' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)
      writer.close

      csv = CSV.read(path)
      expect(csv.length).to eq(1)
      expect(csv[0]).to eq(WaybackArchiver::Report::COLUMNS)
    end

    it 'appends rows as results are written' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)
      writer.write_result(success_result)
      writer.write_result(error_result)
      writer.close

      csv = CSV.read(path)
      expect(csv.length).to eq(3) # header + 2 rows
      expect(csv[1][0]).to eq('http://example.com')
      expect(csv[1][1]).to eq('true')
      expect(csv[1][3]).to eq('spn2-abc123')
      expect(csv[2][0]).to eq('http://example.com/broken')
      expect(csv[2][1]).to eq('false')
    end

    it 'flushes each result to disk immediately' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)
      writer.write_result(success_result)

      # Read without closing — result should already be on disk
      csv = CSV.read(path)
      expect(csv.length).to eq(2) # header + 1 row
      expect(csv[1][0]).to eq('http://example.com')

      writer.close
    end
  end

  describe 'JSON format' do
    it 'writes JSONL (one JSON object per line)' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.write_result(success_result)
      writer.write_result(error_result)
      writer.close

      lines = File.readlines(path).map(&:chomp).reject(&:empty?)
      expect(lines.length).to eq(2)

      first = JSON.parse(lines[0])
      expect(first['url']).to eq('http://example.com')
      expect(first['success']).to eq(true)
      expect(first['job_id']).to eq('spn2-abc123')

      second = JSON.parse(lines[1])
      expect(second['url']).to eq('http://example.com/broken')
      expect(second['success']).to eq(false)
      expect(second['error']).to eq('connection failed')
    end

    it 'produces an empty file when no results are written' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.close

      expect(File.read(path)).to eq('')
    end

    it 'flushes each result to disk immediately' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.write_result(success_result)

      # Read without closing
      line = File.readlines(path).first
      entry = JSON.parse(line)
      expect(entry['url']).to eq('http://example.com')

      writer.close
    end

    it 'accepts .jsonl extension' do
      path = File.join(@tmpdir, 'report.jsonl')
      writer = described_class.new(path)
      writer.write_result(success_result)
      writer.close

      entry = JSON.parse(File.readlines(path).first)
      expect(entry['url']).to eq('http://example.com')
    end
  end

  describe 'unsupported format' do
    it 'raises ArgumentError' do
      path = File.join(@tmpdir, 'report.xml')
      expect { described_class.new(path) }
        .to raise_error(ArgumentError, /Unsupported report format/)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent writes without corruption' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)

      threads = 10.times.map do
        Thread.new do
          5.times { writer.write_result(success_result) }
        end
      end
      threads.each(&:join)
      writer.close

      csv = CSV.read(path)
      expect(csv.length).to eq(51) # header + 50 rows
    end
  end

  describe '#close' do
    it 'is idempotent' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)
      writer.close
      expect { writer.close }.not_to raise_error
    end
  end
end
