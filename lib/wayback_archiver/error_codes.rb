module WaybackArchiver
  # Registry of SPN2 status_ext error codes with human-readable messages
  # and category classification for retry decisions.
  #
  # Source: SPN2 Public API Docs (Vangelis Banos, 2025-10)
  module ErrorCodes
    # @return [Symbol] :transient, :daily_limit, or :permanent
    CATEGORIES = %i[transient daily_limit permanent].freeze

    REGISTRY = {
      # -- Transient: system-side issues that may resolve on retry --
      'error:too-many-requests'        => { message: 'Target host blocking SPN (HTTP 429)',            category: :transient },
      'error:user-session-limit'       => { message: 'User hit concurrent active capture limit',       category: :transient },
      'error:service-unavailable'      => { message: 'Service unavailable (HTTP 503)',                 category: :transient },
      'error:cannot-fetch'             => { message: 'Cannot fetch due to system overload',            category: :transient },
      'error:no-browsers-available'    => { message: 'Headless browser cannot run',                    category: :transient },
      'error:celery'                   => { message: 'Cannot start capture task',                      category: :transient },
      'error:proxy-error'              => { message: 'SPN2 backend proxy error',                       category: :transient },
      'error:internal-server-error'    => { message: 'SPN internal server error',                      category: :transient },
      'error:job-failed'               => { message: 'Capture failed due to system error',             category: :transient },
      'error:browsing-timeout'         => { message: 'Headless browser timeout',                       category: :transient },
      'error:soft-time-limit-exceeded' => { message: 'Capture exceeded 45s time limit',                category: :transient },
      'error:read-timeout'             => { message: 'HTTP connection read timeout',                   category: :transient },
      'error:protocol-error'           => { message: 'HTTP connection broken',                         category: :transient },
      'error:gateway-timeout'          => { message: 'Target server timeout (HTTP 504)',               category: :transient },
      'error:bad-gateway'              => { message: 'Bad Gateway (HTTP 502)',                         category: :transient },
      'error:capture-location-error'   => { message: 'Cannot find created capture location',           category: :transient },
      'error:no-captures'              => { message: 'Capture produced no content',                     category: :transient },

      # -- Daily limit: won't succeed on immediate retry, resets next day --
      'error:too-many-daily-captures'     => { message: 'URL captured 10 times today',                    category: :daily_limit },
      'error:max-daily-bandwidth'         => { message: 'Authenticated user exceeded 5GB daily limit',    category: :daily_limit },
      'error:max-daily-bandwidth-from-ip' => { message: 'Anonymous user exceeded 2GB daily limit',        category: :daily_limit },
      'error:max-daily-bandwidth-host'    => { message: 'Host exceeded 100GB daily limit',                category: :daily_limit },

      # -- Permanent: inherent to the URL or request, retry won't help --
      'error:blocked-url'                       => { message: 'URL on block list (Mozilla web tracker lists)',     category: :permanent },
      'error:blocked'                           => { message: 'Target site blocking SPN (HTTP 999)',               category: :permanent },
      'error:blocked-client-ip'                 => { message: 'Client IP in spam/exploit registries',              category: :permanent },
      'error:invalid-url-syntax'                => { message: 'Invalid URL syntax',                                category: :permanent },
      'error:invalid-host-resolution'           => { message: 'Cannot resolve target host',                        category: :permanent },
      'error:invalid-server-response'           => { message: 'Invalid headers or content encoding from target',   category: :permanent },
      'error:not-found'                         => { message: 'Target URL not found (HTTP 404)',                   category: :permanent },
      'error:no-access'                         => { message: 'Access denied (HTTP 403)',                          category: :permanent },
      'error:unauthorized'                      => { message: 'Authentication required (HTTP 401)',                category: :permanent },
      'error:bad-request'                       => { message: 'Invalid request syntax (HTTP 400)',                 category: :permanent },
      'error:filesize-limit'                    => { message: 'Resource over 2GB cannot be captured',              category: :permanent },
      'error:too-many-redirects'                => { message: 'Too many redirects (max 3)',                        category: :permanent },
      'error:ftp-access-denied'                 => { message: 'FTP resource access denied',                       category: :permanent },
      'error:method-not-allowed'                => { message: 'Request method disabled (HTTP 405)',                category: :permanent },
      'error:not-implemented'                   => { message: 'Request method not supported (HTTP 501)',           category: :permanent },
      'error:http-version-not-supported'        => { message: 'HTTP version not supported (HTTP 505)',             category: :permanent },
      'error:network-authentication-required'   => { message: 'Network authentication required (HTTP 511)',        category: :permanent },
      'error:bandwidth-limit-exceeded'          => { message: 'Target server bandwidth limit exceeded (HTTP 509)', category: :permanent },
    }.freeze

    # Return the error category for a status_ext code.
    # @param status_ext [String, nil] the SPN2 status_ext value
    # @return [Symbol, nil] :transient, :daily_limit, :permanent, or nil
    def self.category(status_ext)
      return nil if status_ext.nil?

      entry = REGISTRY[status_ext]
      if entry
        entry[:category]
      else
        WaybackArchiver.logger.warn("Unknown SPN2 error code: #{status_ext}, treating as transient")
        :transient
      end
    end

    # Whether the error code should trigger a retry.
    # @param status_ext [String, nil] the SPN2 status_ext value
    # @return [Boolean]
    def self.retryable?(status_ext)
      category(status_ext) == :transient
    end

    # Return the human-readable message for a status_ext code.
    # @param status_ext [String, nil] the SPN2 status_ext value
    # @return [String, nil] message string, or nil for nil input
    def self.message(status_ext)
      return nil if status_ext.nil?

      entry = REGISTRY[status_ext]
      entry ? entry[:message] : status_ext
    end
  end
end
