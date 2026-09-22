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
    it 'writes a valid JSON array' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.write_result(success_result)
      writer.write_result(error_result)
      writer.close

      data = JSON.parse(File.read(path))
      expect(data.length).to eq(2)

      first = data[0]
      expect(first['url']).to eq('http://example.com')
      expect(first['success']).to eq(true)
      expect(first['job_id']).to eq('spn2-abc123')

      second = data[1]
      expect(second['url']).to eq('http://example.com/broken')
      expect(second['success']).to eq(false)
      expect(second['error']).to eq('connection failed')
    end

    it 'produces an empty JSON array when no results are written' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.close

      expect(JSON.parse(File.read(path))).to eq([])
    end

    it 'flushes each result to disk immediately' do
      path = File.join(@tmpdir, 'report.json')
      writer = described_class.new(path)
      writer.write_result(success_result)

      # Read without closing
      data = JSON.parse(File.read(path))
      expect(data.first['url']).to eq('http://example.com')

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

    it 'keeps existing JSON results when opened in append mode' do
      path = File.join(@tmpdir, 'report.json')
      first = described_class.new(path)
      first.write_result(success_result)
      first.close

      resumed = described_class.new(path, append: true)
      resumed.write_result(error_result)
      resumed.close

      expect(JSON.parse(File.read(path)).map { |entry| entry['url'] })
        .to eq(%w[http://example.com http://example.com/broken])
    end
  end

  describe 'append mode' do
    it 'keeps the existing CSV header and rows' do
      path = File.join(@tmpdir, 'report.csv')
      first = described_class.new(path)
      first.write_result(success_result)
      first.close

      resumed = described_class.new(path, append: true)
      resumed.write_result(error_result)
      resumed.close

      csv = CSV.read(path)
      expect(csv.count { |row| row == WaybackArchiver::Report::COLUMNS }).to eq(1)
      expect(csv.drop(1).map(&:first)).to eq(%w[http://example.com http://example.com/broken])
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

    it 'makes subsequent writes a safe no-op instead of raising IOError' do
      path = File.join(@tmpdir, 'report.csv')
      writer = described_class.new(path)
      writer.close
      expect { writer.write_result(success_result) }.not_to raise_error
    end
  end
end
