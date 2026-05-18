require 'csv'
require 'json'

module WaybackArchiver
  # Write archive or check results to CSV or JSON files
  class Report
    COLUMNS = %w[url success wayback_url job_id timestamp duration_sec screenshot_url status_ext error_category error].freeze
    CHECK_COLUMNS = %w[url archived timestamp wayback_url].freeze

    # Write results to a file. Format is detected from the file extension.
    # Accepts either Array<ArchiveResult> or Array<CheckResult>.
    # @param results [Array] the results to write.
    # @param path [String] output file path (.csv or .json).
    # @raise [ArgumentError] if the file extension is not supported.
    def self.write(results, path)
      check_mode = results.any? && results.first.is_a?(CheckResult)
      case File.extname(path).downcase
      when '.csv'  then check_mode ? write_check_csv(results, path) : write_csv(results, path)
      when '.json' then check_mode ? write_check_json(results, path) : write_json(results, path)
      else
        raise ArgumentError, "Unsupported report format: #{File.extname(path)}. Use .csv or .json"
      end
    end

    def self.write_csv(results, path)
      CSV.open(path, 'w') do |csv|
        csv << COLUMNS
        results.each { |r| csv << result_row(r) }
      end
    end
    private_class_method :write_csv

    def self.write_json(results, path)
      data = results.map { |r| result_hash(r) }
      File.write(path, JSON.pretty_generate(data))
    end
    private_class_method :write_json

    def self.write_check_csv(results, path)
      CSV.open(path, 'w') do |csv|
        csv << CHECK_COLUMNS
        results.each { |r| csv << check_to_row(r) }
      end
    end
    private_class_method :write_check_csv

    def self.write_check_json(results, path)
      data = results.map { |r| check_to_hash(r) }
      File.write(path, JSON.pretty_generate(data))
    end
    private_class_method :write_check_json

    def self.result_row(result)
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

    def self.result_hash(result)
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

    def self.check_to_row(result)
      [result.url, result.archived?, result.timestamp, result.wayback_url]
    end
    private_class_method :check_to_row

    def self.check_to_hash(result)
      {
        'url'        => result.url,
        'archived'   => result.archived?,
        'timestamp'  => result.timestamp,
        'wayback_url' => result.wayback_url
      }
    end
    private_class_method :check_to_hash
  end
end
