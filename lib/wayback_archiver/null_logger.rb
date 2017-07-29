require 'logger'

module WaybackArchiver
  # Don't log anyting / Send the logs to the abyss
  class NullLogger < Logger
    # Allow any and all params
    def initialize(*args); end

    # Allow any and alls params and don't do anyting
    def add(*args, &block); end
  end
end
