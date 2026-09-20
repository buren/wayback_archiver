require 'csv'
require 'json'
require 'wayback_archiver/report'

module WaybackArchiver
  # Progressive report writer that appends results as they complete.
  # Thread-safe. Each result is flushed to disk immediately, so a crash
  # preserves all results up to that point.
  #
  # CSV files get a header row on construction and one data row per result.
  # JSON files remain valid arrays after each write; JSONL files use one JSON
  # object per line.
  # @api private
  class ReportWriter
    attr_reader :path

    # @param path [String] output file path (.csv, .json, or .jsonl)
    # @param append [Boolean] preserve and append to an existing report
    # @raise [ArgumentError] if the file extension is not supported
    def initialize(path, append: false)
      @path = path
      @format = detect_format(path)
      @mutex = Mutex.new
      @append = append
      open_file
    end

    # Append one result. Thread-safe.
    # @param result [ArchiveResult]
    def write_result(result)
      @mutex.synchronize do
        next if @file.closed?

        case @format
        when :csv   then @file.puts(Report.result_row(result).to_csv)
        when :json  then write_json_result(result)
        when :jsonl then @file.puts(JSON.generate(Report.result_hash(result)))
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
      when '.json' then :json
      when '.jsonl' then :jsonl
      else
        raise ArgumentError, "Unsupported report format: #{File.extname(path)}. Use .csv, .json, or .jsonl"
      end
    end

    def write_header
      @file.puts(Report::COLUMNS.to_csv)
      @file.flush
    end

    def open_file
      case @format
      when :csv
        existing = @append && File.exist?(@path) && !File.empty?(@path)
        @file = File.open(@path, @append ? 'a' : 'w')
        write_header unless existing
      when :jsonl
        @file = File.open(@path, @append ? 'a' : 'w')
      when :json
        open_json_file
      end
    end

    # Keep .json valid after every completed write while retaining progressive
    # flushing. The closing bracket is overwritten and immediately restored as
    # part of the same write; .jsonl remains the simpler append-only format.
    def open_json_file
      if @append && File.exist?(@path) && !File.empty?(@path)
        data = JSON.parse(File.read(@path))
        raise ArgumentError, "Existing JSON report must contain an array: #{@path}" unless data.is_a?(Array)

        @json_has_entries = data.any?
        @file = File.open(@path, 'r+')
        normalized = JSON.generate(data)
        @file.rewind
        @file.write(normalized)
        @file.truncate(@file.pos)
        @file.flush
        @file.seek(-1, IO::SEEK_END)
      else
        @json_has_entries = false
        @file = File.open(@path, 'w+')
        @file.write('[]')
        @file.flush
      end
    rescue JSON::ParserError => e
      raise ArgumentError, "Existing JSON report is invalid: #{@path} (#{e.message})"
    end

    def write_json_result(result)
      @file.seek(-1, IO::SEEK_END)
      separator = @json_has_entries ? ",\n" : ''
      @file.write("#{separator}#{JSON.generate(Report.result_hash(result))}]")
      @json_has_entries = true
    end
  end
end
