module WaybackArchiver
  class ProcessUrls
    def self.call(urls_queue, max_threads: 20)
      puts 'calling '
      threads = max_threads.times.map do
        puts 'threading'
         Thread.new do
           puts 'thread start'
           until urls_queue.empty?
             url = urls_queue.pop.to_s
             print "Saving url #{url} ... "
             WaybackArchiver.save(url)
             print "Saved. \n"
           end
         end
       end
       threads.map(&:join) # Wait for each thread
    end
  end
end
