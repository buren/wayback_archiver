require 'logger'

# Test logger
class TestLogger < Logger
  attr_reader :info_log, :debug_log, :error_log

  def initialize(*_args)
    @info_log = []
    @debug_log = []
    @error_log = []
  end

  def add(*args)
    log_type, _, log_string = args
    case log_type
    when 0 then @debug_log
    when 1 then @info_log
    when 3 then @error_log
    end << log_string
  end
end
