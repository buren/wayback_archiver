require 'json'
require 'securerandom'
require 'time'
require 'set'
require 'tmpdir'

module WaybackArchiver
  # Append-only JSONL session file for crash recovery and resumable archiving.
  # Each line records the result of one URL archive attempt.
  # @api private
  class SessionFile
    attr_reader :path

    # Generate an auto-path in /tmp based on current timestamp.
    # @return [String] path like /tmp/wayback_archiver_20260331_143022.jsonl
    # Timestamped for recognisability, with a random suffix because the
    # timestamp alone collided for runs starting in the same second — they
    # shared one append-only file with independent mutexes, and either could
    # delete the other's recovery data on a clean finish.
    def self.auto_path
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      File.join(Dir.tmpdir, "wayback_archiver_#{stamp}_#{SecureRandom.hex(4)}.jsonl")
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
        next if @file.closed?

        @file.puts(line)
        @file.flush
      end
    end

    # Only confirmed successes may be skipped without checking their status.
    # @return [Set<String>] successfully completed URLs
    def completed_urls
      latest_records.select { |_url, data| data['success'] == true && !pending_record?(data) }.keys.to_set
    end

    # Old session files already store job IDs on interim submission records.
    # Keep even missing IDs here so they cannot fall through to a fresh submit.
    # @return [Hash] URL => {job_id:, since:}; job_id may be nil, and since is
    #   when the URL *first* went pending, not when we last gave up on it.
    def pending_jobs
      first_pending = {}
      records = {}
      each_record do |data|
        url = data['url']
        records[url] = data
        if pending_record?(data)
          first_pending[url] ||= data['recorded_at']
        else
          # A confirmed outcome ends this pending stretch; a later resubmission
          # starts a fresh one rather than inheriting the old clock.
          first_pending.delete(url)
        end
      end

      records.each_with_object({}) do |(url, data), pending|
        next unless pending_record?(data)

        pending[url] = { job_id: data['job_id'], since: first_pending[url] }
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

    # Close and delete the session file.
    def delete!
      close
      File.delete(@path)
    rescue Errno::ENOENT
      # Already gone
    end

    private

    # Last-write-wins, including transitions from submitted/incomplete to a
    # confirmed success or failure. Ignore incomplete lines left by a crash.
    def latest_records
      records = {}
      each_record { |data| records[data['url']] = data }
      records
    end

    # Yields every well-formed record in file order.
    def each_record
      File.foreach(@path) do |line|
        data = JSON.parse(line)
        unless data.is_a?(Hash) && data['url'].is_a?(String) && !data['url'].empty?
          WaybackArchiver.logger.warn('Skipping invalid session record')
          next
        end
        yield data
      rescue JSON::ParserError
        WaybackArchiver.logger.warn("Skipping corrupt session line: #{line.chomp}")
      end
    rescue Errno::ENOENT
      nil
    end

    def pending_record?(data)
      data['submitted'] == true || data['status_ext'].to_s.start_with?('incomplete:')
    end

    def serialize(result)
      {
        'url'        => result.uri,
        # When we learned this state. For a submitted record that is the
        # submission time, which is what dates an unresolved job later.
        'recorded_at' => Time.now.utc.iso8601,
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
