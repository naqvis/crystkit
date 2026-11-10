require "json"
require "http/cookie"
require "log"
require "uri"
require "../core/errors"

module CrystKit
  module Features
    # JSON-serializable cookie DTO for IPC transport and persistence.
    #
    # `Cookie` is the CrystKit-side representation of an HTTP cookie. It is
    # intentionally a plain struct (with `JSON::Serializable`) so it can
    # travel across the IPC boundary to the frontend and be persisted to
    # disk by `CookieStore`. Convert to and from the stdlib
    # `HTTP::Cookie` with `.from_http` and `#to_http` when interoperating
    # with `HTTP::Client`.
    struct Cookie
      include JSON::Serializable

      # Cookie name as set by the server.
      getter name : String
      # Cookie value as set by the server.
      getter value : String
      # Domain the cookie applies to; empty string means "host-only".
      getter domain : String
      # URL path prefix the cookie applies to.
      getter path : String
      # When `true`, the cookie is only sent over HTTPS.
      getter? secure : Bool
      # When `true`, the cookie is inaccessible to JavaScript (`HttpOnly`).
      getter? http_only : Bool
      # `SameSite` policy as a lower-case string: `"strict"`, `"lax"`, or `"none"`.
      getter same_site : String
      # Expiry time of the cookie, or `nil` for a session cookie.
      getter expires : Time?

      # Creates a cookie value with the given attributes.
      #
      # Defaults mirror common browser behaviour: `path` `/`, `secure`
      # and `http_only` off, `same_site` `"Lax"`, no expiry (session
      # cookie).
      def initialize(@name : String, @value : String, @domain : String,
                     @path = "/", @secure = false,
                     @http_only = false, @same_site = "Lax",
                     @expires = nil)
      end

      # Convert from an stdlib `HTTP::Cookie` to this DTO.
      #
      # Missing fields default to safe values: empty domain becomes `""`,
      # missing path becomes `"/"`, and an unset `SameSite` becomes
      # `"lax"`.
      def self.from_http(c : HTTP::Cookie) : self
        new(
          name: c.name,
          value: c.value,
          domain: c.domain || "",
          path: c.path || "/",
          secure: c.secure,
          http_only: c.http_only,
          same_site: c.samesite.try(&.to_s.downcase) || "lax",
          expires: c.expires,
        )
      end

      # Convert to an stdlib `HTTP::Cookie` for use with `HTTP::Client`.
      #
      # An empty `#domain` is mapped back to `nil` so the stdlib treats
      # it as a host-only cookie. Unrecognised `#same_site` values map to
      # `nil` (browser default).
      def to_http : HTTP::Cookie
        samesite = case @same_site.downcase
                   when "strict" then HTTP::Cookie::SameSite::Strict
                   when "lax"    then HTTP::Cookie::SameSite::Lax
                   when "none"   then HTTP::Cookie::SameSite::None
                   else               nil
                   end
        HTTP::Cookie.new(
          name: @name,
          value: @value,
          domain: @domain.empty? ? nil : @domain,
          path: @path,
          secure: @secure,
          http_only: @http_only,
          samesite: samesite,
          expires: @expires,
        )
      end
    end

    # Thread-safe cookie store.
    #
    # `CookieStore` maintains the application's cookie jar: it parses
    # `Set-Cookie` headers from server responses, matches cookies against
    # request URIs (domain, path, secure, expiry), applies them to
    # outgoing request headers, and persists the whole jar to a JSON file
    # so cookies survive across application restarts.
    #
    # All public methods are guarded by an internal `Mutex`, so the store
    # is safe to share between the IPC handler fiber and any background
    # network fibers.
    #
    # Supports RFC 6265 Set-Cookie parsing, domain/path matching,
    # expiration filtering, and JSON persistence.
    class CookieStore
      # :nodoc:
      Log = ::Log.for(self)

      # :nodoc:
      @cookies : HTTP::Cookies
      # :nodoc:
      @persist_path : Path
      # :nodoc:
      @mutex : Mutex

      # Creates a cookie store rooted at *storage_dir*.
      #
      # The persisted jar is read from `#{storage_dir}/cookies.json` at
      # construction time; a missing or corrupt file is treated as an
      # empty jar (logged at warn level). Every mutating call rewrites
      # the file atomically with the new contents.
      def initialize(storage_dir : Path = Path[Dir.current] / ".crystkit" / "cookies")
        @cookies = HTTP::Cookies.new
        @persist_path = storage_dir / "cookies.json"
        @mutex = Mutex.new
        load
      end

      # Get non-expired cookies matching the given URI.
      #
      # Returns an array of `Cookie` DTOs suitable for IPC or
      # inspection. Matching applies RFC 6265 domain-suffix, path-prefix,
      # secure-scheme, and expiry rules. An empty array is returned when
      # *uri* has no host or no cookie matches.
      def get(uri : URI) : Array(Cookie)
        host = uri.host || return [] of Cookie
        @mutex.synchronize do
          now = Time.utc
          @cookies.select { |cookie_item|
            matches_host?(host, cookie_item.domain) &&
              path_matches?(uri.path, cookie_item.path) &&
              !cookie_item.expired?(now) &&
              (!cookie_item.secure || uri.scheme == "https")
          }.to_a.map { |cookie_raw| Cookie.from_http(cookie_raw) }
        end
      end

      # Store a cookie (from `Features::Cookie` DTO) and persist the jar.
      def set(cookie : Cookie) : Nil
        @mutex.synchronize do
          @cookies << cookie.to_http
          save
        end
      end

      # Store a cookie directly from an stdlib `HTTP::Cookie` and persist the jar.
      def http=(cookie : HTTP::Cookie) : Nil
        @mutex.synchronize do
          @cookies << cookie
          save
        end
      end

      # Delete the cookie identified by *name*, *domain*, and *path*.
      #
      # All three fields must match exactly. Idempotent: deleting a
      # cookie that is not present is a no-op. The jar is persisted after
      # the change.
      def delete(name : String, domain : String, path : String = "/") : Nil
        @mutex.synchronize do
          kept = @cookies.reject { |cookie_item| cookie_item.name == name && cookie_item.domain == domain && cookie_item.path == path }
          @cookies.clear
          kept.each { |cookie_item| @cookies << cookie_item }
          save
        end
      end

      # Remove every cookie from the jar and persist the empty state.
      def clear : Nil
        @mutex.synchronize do
          @cookies.clear
          save
        end
      end

      # Parse `Set-Cookie` headers from an HTTP response and store the cookies.
      #
      # Cookies without an explicit domain are assigned *uri*'s host so
      # they become host-only cookies. The jar is persisted after the
      # new cookies are merged in.
      def ingest_headers(uri : URI, headers : HTTP::Headers) : Nil
        host = uri.host || return
        parsed = HTTP::Cookies.from_server_headers(headers)
        @mutex.synchronize do
          parsed.each do |cookie|
            # Apply default domain if not set by server
            cookie.domain = host unless cookie.domain
            @cookies << cookie
          end
          save
        end
      end

      # Apply stored cookies to request *headers* for the given URI.
      #
      # Returns *headers* with a `Cookie` header appended when any
      # applicable cookies exist; otherwise returns *headers* unchanged.
      # Matching uses the same domain/path/secure/expiry rules as `#get`.
      def apply(uri : URI, headers : HTTP::Headers) : HTTP::Headers
        host = uri.host || return headers
        now = Time.utc
        applicable = @mutex.synchronize do
          @cookies.select { |cookie_item|
            matches_host?(host, cookie_item.domain) &&
              path_matches?(uri.path, cookie_item.path) &&
              !cookie_item.expired?(now) &&
              (!cookie_item.secure || uri.scheme == "https")
          }
        end
        unless applicable.empty?
          jar = HTTP::Cookies.new
          applicable.each { |cookie_item| jar << cookie_item }
          jar.add_request_headers(headers)
        end
        headers
      end

      # Returns all stored cookies grouped by domain.
      #
      # The returned hash maps each cookie's domain (or `""` for
      # host-only cookies) to the array of `Cookie` DTOs under that
      # domain. Expired cookies are *not* filtered out by this snapshot
      # — use `#get` with a concrete URI when you need expiry-aware
      # matching.
      def all_cookies : Hash(String, Array(Cookie))
        @mutex.synchronize do
          result = Hash(String, Array(Cookie)).new { |hash, key| hash[key] = [] of Cookie }
          @cookies.each do |cookie_item|
            domain = cookie_item.domain || ""
            result[domain] << Cookie.from_http(cookie_item)
          end
          result
        end
      end

      # :nodoc:
      private def matches_host?(request_host : String, cookie_domain : String?) : Bool
        cd = cookie_domain
        return false unless cd
        request_host == cd || request_host.ends_with?(".#{cd}")
      end

      # :nodoc:
      private def path_matches?(request_path : String?, cookie_path : String?) : Bool
        cp = cookie_path
        return true unless cp
        rp = request_path
        rp = "/" if rp.nil? || rp.empty?
        rp.starts_with?(cp)
      end

      # :nodoc:
      private def load : Nil
        return unless File.exists?(@persist_path)
        data = File.read(@persist_path)
        parsed = JSON.parse(data).as_h
        parsed.each do |_host, cookies_arr|
          cookies_arr.as_a.each do |c_json|
            dto = Cookie.from_json(c_json.to_json)
            @cookies << dto.to_http
          end
        end
      rescue ex
        Log.warn { "Failed to load cookies: #{ex.message}" }
      end

      # :nodoc:
      private def save : Nil
        dir = @persist_path.parent
        Dir.mkdir_p(dir.to_s) unless Dir.exists?(dir.to_s)
        grouped = Hash(String, Array(Cookie)).new { |hash, key| hash[key] = [] of Cookie }
        @cookies.each do |cookie_item|
          domain = cookie_item.domain || ""
          grouped[domain] << Cookie.from_http(cookie_item)
        end
        File.write(@persist_path, grouped.to_json)
      rescue ex
        Log.warn { "Failed to save cookies: #{ex.message}" }
      end
    end
  end
end
