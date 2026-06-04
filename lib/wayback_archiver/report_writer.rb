require 'csv'
require 'json'
require 'wayback_archiver/report'

module WaybackArchiver
  # Progressive report writer that appends results as they complete.
  # Thread-safe. Each result is flushed to disk immediately, so a crash
  # preserves all results up to that point.
  #
  # CSV files get a header row on construction and one data row per result.
  # JSON/JSONL files use JSONL format (one JSON object per line).
  class ReportWriter
    attr_reader :path

    # @param path [String] output file path (.csv, .json, or .jsonl)
    # @raise [ArgumentError] if the file extension is not supported
    def initialize(path)
      @path = path
      @format = detect_format(path)
      @mutex = Mutex.new
      @file = File.open(path, 'w')
      write_header if @format == :csv
    end

    # Append one result. Thread-safe.
    # @param result [ArchiveResult]
    def write_result(result)
      @mutex.synchronize do
        next if @file.closed?

        case @format
        when :csv  then @file.puts(Report.result_row(result).to_csv)
        when :json then @file.puts(JSON.generate(Report.result_hash(result)))
        end
        @file.flush
      end
    end

    # Close the file handle. Safe to call multiple times. Synchronized with
    # write_result so a close during a concurrent write (e.g. from a Ctrl+C
    # signal handler) cannot close the handle mid-puts.
    def close
      @mutex.synchronize do
        next if @file.closed?

        @file.close
      end
    end

    private

    def detect_format(path)
      case File.extname(path).downcase
      when '.csv' then :csv
      when '.json', '.jsonl' then :json
      else
        raise ArgumentError, "Unsupported report format: #{File.extname(path)}. Use .csv, .json, or .jsonl"
      end
    end

    def write_header
      @file.puts(Report::COLUMNS.to_csv)
      @file.flush
    end
  end
end
