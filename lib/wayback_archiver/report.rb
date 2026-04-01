require 'csv'
require 'json'

module WaybackArchiver
  # Write archive results to CSV or JSON files
  class Report
    COLUMNS = %w[url success wayback_url job_id timestamp duration_sec screenshot_url status_ext error_category error].freeze

    # Write results to a file. Format is detected from the file extension.
    # @param results [Array<ArchiveResult>] the results to write.
    # @param path [String] output file path (.csv or .json).
    # @raise [ArgumentError] if the file extension is not supported.
    def self.write(results, path)
      case File.extname(path).downcase
      when '.csv'  then write_csv(results, path)
      when '.json' then write_json(results, path)
      else
        raise ArgumentError, "Unsupported report format: #{File.extname(path)}. Use .csv or .json"
      end
    end

    def self.write_csv(results, path)
      CSV.open(path, 'w') do |csv|
        csv << COLUMNS
        results.each { |r| csv << result_to_row(r) }
      end
    end
    private_class_method :write_csv

    def self.write_json(results, path)
      data = results.map { |r| result_to_hash(r) }
      File.write(path, JSON.pretty_generate(data))
    end
    private_class_method :write_json

    def self.result_to_row(result)
      [
        result.uri,
        result.success?,
        result.wayback_url,
        result.job_id,
        result.timestamp,
        result.duration_sec,
        result.screenshot_url,
        result.status_ext,
        result.error_category&.to_s,
        result.error&.to_s
      ]
    end
    private_class_method :result_to_row

    def self.result_to_hash(result)
      {
        'url'            => result.uri,
        'success'        => result.success?,
        'wayback_url'    => result.wayback_url,
        'job_id'         => result.job_id,
        'timestamp'      => result.timestamp,
        'duration_sec'   => result.duration_sec,
        'screenshot_url' => result.screenshot_url,
        'status_ext'      => result.status_ext,
        'error_category'  => result.error_category&.to_s,
        'error'           => result.error&.to_s
      }
    end
    private_class_method :result_to_hash
  end
end
