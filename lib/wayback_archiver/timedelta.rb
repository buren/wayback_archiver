module WaybackArchiver
  # Parse human-readable time duration strings like "3d 5h 20m" into seconds.
  # Supported units: d (days), h (hours), m (minutes), s (seconds).
  # A bare number is treated as seconds.
  # @api private
  module Timedelta
    UNITS = { 'd' => 86_400, 'h' => 3_600, 'm' => 60, 's' => 1 }.freeze

    # Parse a timedelta string into total seconds.
    # @param str [String] e.g. "3d 5h 20m", "7d", "120"
    # @return [Integer] total seconds
    # @raise [ArgumentError] on invalid format
    def self.parse(str)
      str = str.to_s.strip
      raise ArgumentError, "Empty timedelta string" if str.empty?

      # Bare number = seconds
      return Integer(str) if str.match?(/\A\d+\z/)

      total = 0
      matched = false

      str.scan(/(\d+)\s*([dhms])/i) do |amount, unit|
        total += amount.to_i * UNITS.fetch(unit.downcase)
        matched = true
      end

      raise ArgumentError, "Invalid timedelta format: #{str.inspect}. Use e.g. \"3d 5h 20m\" or \"120\"" unless matched

      total
    end

    # Convert a timedelta string to a CDX API timestamp (YYYYMMDDHHMMSS).
    # Returns the timestamp for (now - timedelta).
    # @param str [String] timedelta string
    # @return [String] 14-digit timestamp
    def self.to_cdx_timestamp(str)
      seconds = parse(str)
      (Time.now - seconds).strftime('%Y%m%d%H%M%S')
    end
  end
end
