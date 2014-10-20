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
      threads.each(&:join)
      all_urls
    end
  end
end
