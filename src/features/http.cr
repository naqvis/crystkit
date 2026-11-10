require "json"
require "http/client"
require "openssl"
require "log"
require "../core/errors"
require "../security/context"
require "./cookie_store"

module CrystKit
  module Features
    # Union of accepted HTTP request body shapes.
    #
    # `String` is sent verbatim, `Bytes` are transferred as raw octets,
    # `JSON::Any` is serialized with `#to_json` and given a
    # `Content-Type: application/json` header automatically, and `nil`
    # represents a bodyless request.
    alias HTTPBody = String | Bytes | JSON::Any | Nil

    # Immutable HTTP response returned by `HTTPClient` request methods.
    #
    # The body is captured as a `Bytes` slice up-front so the response can be
    # safely retained after the request goes out of scope.
    struct HTTPResponse
      getter status : Int32
      getter headers : HTTP::Headers
      getter body : Bytes

      # Creates a response from a status code, header set, and body slice.
      #
      # *body* is retained by reference; mutating the slice after construction
      # mutates the response. Application code receives instances from
      # `HTTPClient#get` and friends rather than constructing them.
      def initialize(@status : Int32, @headers : HTTP::Headers, @body : Bytes)
      end

      # Decodes the body as a UTF-8 string.
      #
      # The conversion is non-validating: invalid UTF-8 sequences are replaced
      # per Crystal's loose semantics. Use this for text responses; for known
      # binary payloads prefer accessing `#body` directly.
      def text : String
        String.new(@body)
      end

      # Parses the body as JSON.
      #
      # Raises `JSON::ParseException` if the body is not valid JSON; callers
      # should rescue when the content type is uncertain.
      def json : JSON::Any
        JSON.parse(text)
      end

      # Returns `true` for 2xx status codes, `false` otherwise.
      def success? : Bool
        @status >= 200 && @status < 300
      end
    end

    # Per-request configuration for `HTTPClient` methods.
    #
    # A value-type bag of headers, query parameters, timeouts, redirect policy,
    # and TLS material.
    #
    # TLS file paths (`ca_cert_path`, `client_cert_path`, `client_key_path`)
    # are silently ignored when they do not exist on disk, allowing callers to
    # opportunistically configure mTLS without branching on file presence.
    struct RequestOptions
      property headers : Hash(String, String)
      property query_params : Hash(String, String)
      property timeout : Time::Span
      property? follow_redirects : Bool
      property max_redirects : Int32
      property? verify_ssl : Bool
      property ca_cert_path : Path?
      property client_cert_path : Path?
      property client_key_path : Path?

      # Creates a default options bag.
      #
      # Defaults: 30-second timeout, redirects followed up to 10 hops, strict
      # TLS verification, no custom CA/client material.
      def initialize(
        @headers : Hash(String, String) = Hash(String, String).new,
        @query_params : Hash(String, String) = Hash(String, String).new,
        @timeout = 30.seconds,
        @follow_redirects = true,
        @max_redirects = 10,
        @verify_ssl = true,
        @ca_cert_path = nil,
        @client_cert_path = nil,
        @client_key_path = nil,
      )
      end
    end

    # HTTP client with capability checks, cookie storage and redirect handling.
    #
    # A single `HTTPClient` instance is intended to be shared across an
    # application: it holds a `Security::Context` and an optional `CookieStore`
    # that participates in every request. Each verb method
    # (`#get`, `#post`, ...) performs a `require_resource!("http:request", url)`
    # check before dispatch, so a denial raises `Core::SecurityError` (code
    # `CAPABILITY_DENIED` or `SCOPE_DENIED`) before any network I/O.
    #
    # Redirects are followed transparently when `RequestOptions#follow_redirects?`
    # is true; cookie injection is re-evaluated against each intermediate URI
    # so cross-origin redirects cannot silently widen authority.
    # Network/timeout/Socket errors are normalized to
    # `Core::NetworkError` with a stable `code`.
    #
    # ```
    # client = CrystKit::Features::HTTPClient.new(security_ctx)
    # res = client.get("https://api.example.com/users",
    #   CrystKit::Features::RequestOptions.new(
    #     headers: {"Authorization" => "Bearer …"}
    #   ))
    # puts res.text if res.success?
    # ```
    class HTTPClient
      Log = ::Log.for(self)

      @security : Security::Context

      # Optional `CookieStore` consulted on every request and updated from
      # every response. When `nil`, no cookie header is added and
      # `Set-Cookie` headers in responses are ignored.
      property cookie_store : CookieStore?

      # Creates a client bound to *security*.
      #
      # The cookie store starts `nil`; assign it post-construction to enable
      # session persistence.
      def initialize(@security : Security::Context)
        @cookie_store = nil
      end

      # Issues a GET request to *url*.
      #
      # Returns the resulting `HTTPResponse`; raises `Core::SecurityError` on
      # denial or `Core::NetworkError` on transport failure.
      def get(url : String, options : RequestOptions = RequestOptions.new) : HTTPResponse
        @security.require_resource!("http:request", url)
        execute(:GET, url, options, nil)
      end

      # Convenience: GET *url* and return the response body as `Bytes`.
      # Applies a *timeout* by copying *options* and overriding its
      # `timeout` field. Raises `Core::NetworkError` on transport failure
      # or `Core::SecurityError` if the security context denies the URL.
      def get_bytes(url : String, timeout : Time::Span? = nil,
                    options : RequestOptions = RequestOptions.new) : Bytes
        opts = options
        opts.timeout = timeout if timeout
        response = get(url, opts)
        response.body
      end

      # Issues a POST request to *url* with an optional *body*.
      #
      # When *body* is a `JSON::Any` the request is sent with
      # `Content-Type: application/json`. See `#get` for the security contract
      # and error modes.
      def post(url : String, body : HTTPBody = nil, options : RequestOptions = RequestOptions.new) : HTTPResponse
        @security.require_resource!("http:request", url)
        execute(:POST, url, options, body)
      end

      # Issues a PUT request to *url* with an optional *body*.
      #
      # See `#post` for body handling and `#get` for the security contract.
      def put(url : String, body : HTTPBody = nil, options : RequestOptions = RequestOptions.new) : HTTPResponse
        @security.require_resource!("http:request", url)
        execute(:PUT, url, options, body)
      end

      # Issues a DELETE request to *url*.
      #
      # See `#get` for the security contract and error modes.
      def delete(url : String, options : RequestOptions = RequestOptions.new) : HTTPResponse
        @security.require_resource!("http:request", url)
        execute(:DELETE, url, options, nil)
      end

      # Issues a PATCH request to *url* with an optional *body*.
      #
      # See `#post` for body handling and `#get` for the security contract.
      def patch(url : String, body : HTTPBody = nil, options : RequestOptions = RequestOptions.new) : HTTPResponse
        @security.require_resource!("http:request", url)
        execute(:PATCH, url, options, body)
      end

      # :nodoc:
      private def new_client(uri : URI, options : RequestOptions) : HTTP::Client
        client = HTTP::Client.new(uri)
        client.connect_timeout = options.timeout
        client.read_timeout = options.timeout

        if uri.scheme == "https" && !options.verify_ssl?
          client.tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
          # Only warn when the downgrade is not an obvious local/dev target.
          # Hitting localhost / private-range hosts with verify_ssl: false is
          # an explicit, expected dev choice; hitting a public host is the
          # surprising case worth surfacing once.
          if external_tls_bypass?(uri)
            Log.warn { "TLS verification disabled (verify_ssl: false) for external host #{uri.host}; connections are exposed to MITM. Use ca_cert_path for self-signed certs in production." }
          end
        end

        if uri.scheme == "https"
          tls = client.tls
          if ca = options.ca_cert_path
            tls.ca_certificates = ca.to_s if File.exists?(ca)
          end
          if (cert = options.client_cert_path) && (key = options.client_key_path)
            if File.exists?(cert) && File.exists?(key)
              tls.certificate_chain = cert.to_s
              tls.private_key = key.to_s
            end
          end
        end

        client
      end

      # True when *uri* is an HTTPS endpoint on a public (non-loopback,
      # non-private-range) host and TLS verification is being disabled. Such
      # a downgrade is almost always unintentional and exposes the connection
      # to interception, so callers get a single warning. Localhost and
      # RFC1918/private addresses are treated as expected dev targets and
      # stay silent.
      private def external_tls_bypass?(uri : URI) : Bool
        host = uri.host
        return false unless host
        return false if host == "localhost" || host.ends_with?(".localhost") || host == "127.0.0.1" || host == "::1"
        # Private IPv4 ranges (10/8, 172.16/12, 192.168/16) and link-local.
        if m = host.match(/\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/)
          a, b = m[1].to_i, m[2].to_i
          return false if a == 10
          return false if a == 172 && b >= 16 && b <= 31
          return false if a == 192 && b == 168
          return false if a == 169 && b == 254
        end
        true
      end

      # :nodoc:
      private def execute(method : Symbol, url : String, options : RequestOptions, body : HTTPBody) : HTTPResponse
        uri = build_uri(url, options.query_params)
        client = new_client(uri, options)

        headers = HTTP::Headers.new
        options.headers.each { |k, v| headers[k] = v }

        if body.is_a?(JSON::Any)
          headers["Content-Type"] = "application/json"
        end

        body_str = case body
                   when String    then body
                   when JSON::Any then body.to_json
                   when Bytes     then String.new(body)
                   else                nil
                   end

        redirects = 0
        loop do
          if (cs = @cookie_store) && (cookies = cs.get(uri); !cookies.empty?)
            cookie_str = cookies.map { |cookie_item| "#{URI.encode_www_form(cookie_item.name)}=#{URI.encode_www_form(cookie_item.value)}" }.join("; ")
            headers["Cookie"] = cookie_str
          end

          response = client.exec(method.to_s, uri.request_target, headers, body_str)

          if options.follow_redirects? && response.status.redirection?
            redirects += 1
            if redirects > options.max_redirects
              raise Core::NetworkError.new(
                "Too many redirects (max #{options.max_redirects})",
                code: "TOO_MANY_REDIRECTS"
              )
            end
            location = response.headers["Location"]?
            unless location
              Log.warn { "Redirect #{response.status_code} with no Location header from #{url}; treating response as final" }
              return HTTPResponse.new(status: response.status_code, headers: response.headers, body: response.body.to_slice)
            end
            uri = URI.parse(location)
            client = new_client(uri, options)
            next
          end

          @cookie_store.try(&.ingest_headers(uri, response.headers))

          return HTTPResponse.new(
            status: response.status_code,
            headers: response.headers,
            body: response.body.to_slice
          )
        end
      rescue ex : IO::TimeoutError
        raise Core::NetworkError.new("Request timed out: #{url}", code: "TIMEOUT")
      rescue ex : Socket::Error
        raise Core::NetworkError.new("Connection error: #{ex.message}", code: "CONNECTION_ERROR")
      rescue ex : Core::NetworkError | Core::SecurityError
        raise ex
      rescue ex
        raise Core::NetworkError.new("HTTP request failed: #{ex.message}", code: "REQUEST_FAILED")
      end

      # :nodoc:
      private def build_uri(url : String, query_params : Hash(String, String)) : URI
        uri = URI.parse(url)
        unless query_params.empty?
          existing = uri.query || ""
          params = HTTP::Params.new
          # Parse existing params
          HTTP::Params.parse(existing).each { |k, v| params.add(k, v) } unless existing.empty?
          query_params.each { |k, v| params.add(k, v) }
          uri = URI.new(uri.scheme, uri.host, uri.port, uri.path, params.to_s, uri.fragment, uri.user, uri.password)
        end
        uri
      end
    end
  end
end
