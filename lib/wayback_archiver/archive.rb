module WaybackArchiver
  class Archive
    MAX_THREAD_COUNT = 8

    def self.post(all_urls)
      puts "Request are sent with up to #{MAX_THREAD_COUNT} parallel threads"
  
      puts "Total urls to be sent: #{all_urls.length}"
      threads    = []
      group_size = (all_urls.length / MAX_THREAD_COUNT) + 1
      all_urls.each_slice(group_size).to_a.each do |urls|
        threads << Thread.new do
          urls.each_with_index do |url, index|
            resolved_url = Request.resolve_url(url)
            request_url  = "#{BASE_URL}#{resolved_url}"
            begin
              res = Request.get_response(request_url)
              puts "[#{res.code}, #{res.message}] #{resolved_url}"
            rescue Exception => e
              puts "Error message: #{e.message}"
              puts "Failed to archive: #{resolved_url}"
            end
          end
        end
      end
      threads.each(&:join)
      all_urls
    end
  end
end
