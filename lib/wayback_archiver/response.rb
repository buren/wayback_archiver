module WaybackArchiver
  # Response data struct
  Response = Struct.new(:code, :message, :body, :uri, :error)
  class Response
    # Returns true if a successfull response
    # @example check if Response was successfull
    #    response = Response.new('200', 'OK', 'buren', 'http://example.com')
    #    response.success? # => true
    def success?
      HTTPCode.success?(code)
    end
  end
end
