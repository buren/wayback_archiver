require 'json'
require 'set'
require 'tmpdir'

module WaybackArchiver
  # Append-only JSONL session file for crash recovery and resumable archiving.
  # Each line records the result of one URL archive attempt.
  class SessionFile
    attr_reader :path

    # Generate an auto-path in /tmp based on current timestamp.
    # @return [String] path like /tmp/wayback_archiver_20260331_143022.jsonl
    def self.auto_path
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      File.join(Dir.tmpdir, "wayback_archiver_#{stamp}.jsonl")
    end

    # @param path [String] file path for the session file
    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @file = File.open(path, 'a')
    end

    # Append one result as a JSON line. Thread-safe.
    # @param result [ArchiveResult]
    def write_result(result)
      line = JSON.generate(serialize(result))
      @mutex.synchronize do
        @file.puts(line)
        @file.flush
      end
    end

    # Read the session file and return the set of URLs that should be skipped.
    # Includes URLs that succeeded OR were submitted (got a job_id from SPN2).
    # Uses last-write-wins: if a URL appears multiple times, only the
    # latest record determines its status.
    # @return [Set<String>] URLs to skip on resume
    def completed_urls
      records = {}
      File.foreach(@path) do |line|
        data = JSON.parse(line)
        records[data['url']] = data['success'] || data['submitted']
      rescue JSON::ParserError
        # Skip truncated/corrupt lines (e.g. from hard crash)
        WaybackArchiver.logger.warn("Skipping corrupt session line: #{line.chomp}")
      end
      records.select { |_url, completed| completed }.keys.to_set
    rescue Errno::ENOENT
      Set.new
    end

    # Close the file handle. Safe to call multiple times.
    def close
      return if @file.closed?

      @file.close
    end

    # Close and delete the session file.
    def delete!
      close
      File.delete(@path)
    rescue Errno::ENOENT
      # Already gone
    end

    private

    def serialize(result)
      {
        'url'        => result.uri,
        'success'    => result.success?,
        'submitted'  => result.submitted?,
        'job_id'     => result.job_id,
        'timestamp'  => result.timestamp,
        'error'      => result.error&.to_s,
        'status_ext' => result.status_ext
      }
    end
  end
end
