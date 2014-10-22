module WaybackArchiver
  class Archive
    WAYBACK_BASE_URL = 'https://web.archive.org/save/'
    MAX_THREAD_COUNT = 10

    def self.post(urls)
      puts "Request are sent with up to #{MAX_THREAD_COUNT} parallel threads"
      puts "Total urls to be sent: #{urls.length}"
      group_size = (urls.length / MAX_THREAD_COUNT) + 1
      urls.each_slice(group_size).to_a.map! do |archive_urls|
        Thread.new { archive_urls.each { |url| post_url(url) } }
      end.each(&:join)
      puts "#{urls.length} URLs sent to Internet archive"
      urls
    end

    def self.post_url(archive_url)
      resolved_url = Request.resolve_url(archive_url)
      request_url  = "#{WAYBACK_BASE_URL}#{resolved_url}"
      response     = Request.get_response(request_url)
      puts "[#{response.code}, #{response.message}] #{resolved_url}"
    rescue Exception => e
      puts "Error message:     #{e.message}"
      puts "Failed to archive: #{resolved_url}"
    end
  end
end
