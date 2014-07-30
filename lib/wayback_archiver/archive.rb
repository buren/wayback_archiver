module WaybackArchiver
  class Archive

    def self.post(urls)
      urls.each_with_index do |url, index|
        request_url = "#{BASE_URL}#{url}"
        puts "Archiving (#{index + 1}/#{urls.length}): #{url}"
        begin
          res = Request.get_response(request_url)
          puts "#{res.code} => #{res.message}"
        rescue Exception => e
          puts "Error message: #{e.message}"
          puts "Failed to archive: #{url}"
        end
      end
    end

  end
end
