require 'concurrent'

module WaybackArchiver
  # Thread pool
  class ThreadPool
    # Build a thread pool
    # @return [Concurrent::FixedThreadPool/Concurrent::ImmediateExecutor] an instance of a concurrent thread pool
    # @param [Integer] concurrency the desired concurrency
    # @example Build a thread pool with 10 as the desired concurrency
    #    pool = ThreadPool.build(10)
    #    pool.post { some_work } # Returns a Concurrent::FixedThreadPool
    # @example Build a thread pool with 1 as the desired concurrency
    #    pool = ThreadPool.build(1)
    #    pool.post { some_work } # Returns a Concurrent::ImmediateExecutor
    # @see https://github.com/ruby-concurrency/concurrent-ruby/blob/master/doc/thread_pools.md
    def self.build(concurrency)
      if concurrency == 1
        Concurrent::ImmediateExecutor.new
      elsif concurrency > 1
        Concurrent::FixedThreadPool.new(concurrency)
      else
        raise ArgumentError, 'concurrency must be one or greater'
      end
    end
  end
end
