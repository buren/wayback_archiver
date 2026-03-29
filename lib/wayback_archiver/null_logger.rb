require 'logger'

module WaybackArchiver
  # Don't log anything / Send the logs to the abyss
  class NullLogger < Logger
    # Allow any and all params
    def initialize(*args); end

    # Accept any params and discard
    def add(*args, &block); end
  end
end
