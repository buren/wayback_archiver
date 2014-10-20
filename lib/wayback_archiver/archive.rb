module WaybackArchiver
  class Archive
    MAX_THREAD_COUNT = 8

    def self.post(all_urls)
      puts "Request will be sent with max #{MAX_THREAD_COUNT} parallel threads"
  
      puts "Total urls to be sent: #{all_urls.length}"
      threads    = []
      group_size = (all_urls.length / MAX_THREAD_COUNT) + 1
      all_urls.each_slice(group_size).to_a.each do |urls|
        threads << Thread.new do
          urls.each_with_index do |url, index|
            request_url = "#{BASE_URL}#{url}"
            begin
              res = Request.get_response(request_url)
              print "#{url}    #{res.code} => #{res.message} \n"
            rescue Exception => e
              puts "Error message: #{e.message}"
              puts "Failed to archive: #{url}"
            end
          end
        end
      end
      threads.each_with_index do |thread, index|
        print_index = index + 1
        progress = '['
        progress << '#' * print_index
        progress << ' ' * (threads.length - print_index)
        progress << ']'
        procent = ((print_index.to_f/threads.length.to_f) * 100).round(0)
        puts "[PROGRESS] #{progress} #{procent}% (#{print_index}/#{threads.length})"
        thread.join
      end
      all_urls
    end
  end
end
