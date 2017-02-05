require 'thread'

module WaybackArchiver
  class ProcessQueue
    # Process enumerable data in parallel.
    # @return [Array] of URLs defined found during crawl.
    # @param [Object] Enumberable object
    # @example Print list of names in parallel
    #    ProcessQueue.process(%w(jacob peter eva)) { |v| puts n }
    # @example Print list of names using 2 threads
    #    ProcessQueue.process(%w(jacob peter eva), threads_count: 2) { |v| puts n }
    def self.process(data_array, threads_count: 5)
      queue = Queue.new
      data_array.each { |data| queue.push(data) }
      workers = threads_count.times.map do
        Thread.new do
          begin
            while data = queue.pop(true)
              yield(data)
            end
          rescue ThreadError
          end
        end
      end
      workers.map(&:join)
    end
  end
end
