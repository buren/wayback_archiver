require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'
require 'zlib'

require 'wayback_archiver/http_code'
require 'wayback_archiver/response'

module WaybackArchiver
  # Make HTTP requests
  class Request
    # General error, something went wrong
    class Error < StandardError; end
    # Client error, something went wrong on the local machine
    class ClientError < Error; end
    # Server error, the remote server did something wrong
    class ServerError < Error; end
    # Remote server responded with a HTTP error
    class HTTPError < ServerError; end
    # Remote server error
    class ResponseError < ServerError; end
    # Max redirects reached error
    class MaxRedirectError < ServerError; end
    # Remote server responded with an invalid redirect
    class InvalidRedirectError < ServerError; end
    # Remote server responded with an unknown HTTP code
    class UnknownResponseCodeError < ServerError; end

    # GET response wrapper
    GETStruct = Struct.new(:response, :error)

    # Max number of redirects before an error is raised
    MAX_REDIRECTS = 10

    # Known request errors
    REQUEST_ERRORS = {
      # server
      Timeout::Error => ServerError,
      OpenSSL::SSL::SSLError => ServerError,
      Net::HTTPBadResponse => ServerError,
      Zlib::Error => ServerError,
      # client
      SystemCallError => ClientError,
      SocketError => ClientError,
      IOError => ClientError
    }.freeze

    # Get reponse.
    # @return [Response] the http response representation.
    # @param [String, URI] uri to retrieve.
    # @param max_redirects [Integer] max redirects (default: 10).
    # @param follow_redirects [Boolean] follow redirects (default: true).
    # @example Get example.com
    #    Request.get('example.com')
    # @example Get http://example.com and follow max 3 redirects
    #    Request.get('http://example.com', max_redirects: 3)
    # @example Get http://example.com and don't follow redirects
    #    Request.get('http://example.com', follow_redirects: false)
    # @raise [Error] super class of all exceptions that this method can raise
    # @raise [ServerError] all server errors
    # @raise [ClientError] all client errors
    # @raise [HTTPError] all HTTP errors
    # @raise [MaxRedirectError] too many redirects, subclass of HTTPError (only raised if raise_on_http_error flag is true)
    # @raise [ResponseError] server responsed with a 4xx or 5xx HTTP status code, subclass of HTTPError (only raised if raise_on_http_error flag is true)
    # @raise [UnknownResponseCodeError] server responded with an unknown HTTP status code, subclass of HTTPError (only raised if raise_on_http_error flag is true)
    # @raise [InvalidRedirectError] server responded with an invalid redirect, subclass of HTTPError (only raised if raise_on_http_error flag is true)
    def self.get(
      uri,
      max_redirects: MAX_REDIRECTS,
      raise_on_http_error: false,
      follow_redirects: true
    )
      uri = build_uri(uri)

      redirect_count = 0
      until redirect_count > max_redirects
        WaybackArchiver.logger.debug "Requesting #{uri}"

        http = Net::HTTP.new(uri.host, uri.port)
        if uri.scheme == 'https'
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = WaybackArchiver.user_agent

        result = perform_request(uri, http, request)
        response = result.response
        error = result.error

        raise error if error

        code = response.code
        WaybackArchiver.logger.debug "[#{code}, #{response.message}] Requested #{uri}"

        case HTTPCode.type(code)
        when :success
          return build_response(uri, response)
        when :redirect
          return build_response(uri, response) unless follow_redirects

          uri = build_redirect_uri(uri, response)
          redirect_count += 1
          next
        when :error
          if raise_on_http_error
            raise ResponseError, "Failed with response code: #{code} when requesting #{uri}"
          end

          return build_response(uri, response)
        else
          raise UnknownResponseCodeError, "Unknown HTTP response code #{code} when requesting #{uri}"
        end
      end

      raise MaxRedirectError, "Redirected too many times when requesting #{uri}"
    end

    # Builds a Response object.
    # @return [Response]
    # @param [URI] uri that was requested.
    # @param [Net::HTTPResponse] response the server response.
    # @example Build Response object for example.com
    #    Request.build_response(uri, net_http_response)
    def self.build_response(uri, response)
      Response.new(
        response.code,
        response.message,
        parse_body(response.body),
        uri.to_s
      )
    end

    # Builds an URI for a redirect response.
    # @return [URI] to redirect to.
    # @param [URI] uri that was requested.
    # @param [Net::HTTPResponse] response the server response.
    # @example Build redirect URI for example.com (lets pretend it will redirect..)
    #    Request.build_redirect_uri('http://example.com', net_http_response)
    def self.build_redirect_uri(uri, response)
      location_header = response.header.fetch('location') do
        raise InvalidRedirectError, "No location header found on redirect when requesting #{uri}"
      end

      location = URI.parse(location_header)
      return build_uri(uri) + location_header if location.relative?

      location
    end

    # Build URI.
    # @return [URI] uri to redirect to.
    # @param [URI, String] uri to build.
    # @example Build URI for example.com
    #    Request.build_uri('http://example.com')
    # @example Build URI for #<URI::HTTP http://example.com>
    #    uri = URI.parse('http://example.com')
    #    Request.build_uri(uri)
    def self.build_uri(uri)
      return uri if uri.is_a?(URI)

      uri = "http://#{uri}" unless uri =~ %r{^https?://}
      URI.parse(uri)
    end

    # Parse response body, handles reqular and gzipped response bodies.
    # @return [String] the response body.
    # @param [String] response_body the server response body.
    # @example Return response body for response.
    #    Request.parse_body(uri, net_http_response)
    def self.parse_body(response_body)
      return '' unless response_body

      Zlib::GzipReader.new(StringIO.new(response_body)).read
    rescue Zlib::GzipFile::Error => _e
      response_body
    end

    # Return whether a value is blank or not.
    # @return [Boolean] whether the value is blank or not.
    # @param [Object] value the value to check if its blank or not.
    # @example Returns false for nil.
    #    Request.blank?(nil)
    # @example Returns false for empty string.
    #    Request.blank?('')
    # @example Returns false for string with only spaces.
    #    Request.blank?('  ')
    def self.blank?(value)
      return true unless value
      return true if value.strip.empty?

      false
    end

    private

    def self.perform_request(uri, http, request)
      # TODO: Consider retrying failed requests
      response = http.request(request)
      GETStruct.new(response)
    rescue *REQUEST_ERRORS.keys => e
      build_request_error(uri, e, REQUEST_ERRORS.fetch(e.class))
    end

    def self.build_request_error(uri, error, error_wrapper_klass)
      WaybackArchiver.logger.error "Request to #{uri} failed: #{error_wrapper_klass}, #{error.class}, #{error.message}"

      GETStruct.new(
        Response.new,
        error_wrapper_klass.new("#{error.class}, #{error.message}")
      )
    end
  end
end
