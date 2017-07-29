module WaybackArchiver
  # Convience class for HTTP response codes
  class HTTPCode
    # Type of code as symbol
    # @return [Symbol] code type
    # @param [String/Integer] code the response code
    # @example
    #    HttpCode.type('200')
    def self.type(code)
      code = code.to_s
      return :success if success?(code)
      return :redirect if redirect?(code)
      return :error if error?(code)

      :unknown
    end

    # Whether the code is a success type
    # @return [Boolean] is success or not
    # @param [String] code the response code
    # @example
    #    HttpCode.success?('200') # => true
    # @example
    #    HttpCode.success?(200) # => true
    # @example
    #    HttpCode.success?(nil) # => false
    def self.success?(code)
      code.to_s.match?(/2\d\d/)
    end

    # Whether the code is a redirect type
    # @return [Boolean] is redirect or not
    # @param [String] code the response code
    # @example
    #    HttpCode.redirect?('301')
    def self.redirect?(code)
      code.to_s.match?(/3\d\d/)
    end

    # Whether the code is a error type
    # @return [Boolean] is error or not
    # @param [String] code the response code
    # @example
    #    HttpCode.error?('301')
    def self.error?(code)
      code.to_s.match?(/4\d\d/) || code.to_s.match?(/5\d\d/)
    end
  end
end
