require "../base"
require "../../features/cookie_store"

module CrystKit
  module Plugins
    # Plugin exposing an in-process HTTP cookie store to the frontend.
    #
    # Stores cookies per-host, independent of any particular webview. The
    # frontend can query, set, delete, clear, and enumerate cookies by URL or
    # across all hosts. All commands require the `cookie:manage` capability.
    #
    # Registers IPC commands:
    #   cookie.get — List cookies for a URL
    #   cookie.set — Add or update a cookie
    #   cookie.delete — Delete a cookie by name, domain, and path
    #   cookie.clear — Remove every cookie from the store
    #   cookie.all — List all cookies grouped by host
    class Cookie < Plugin::Base
      getter! store : Features::CookieStore

      def identifier : String
        "cookie"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(cookie.get cookie.set cookie.delete cookie.clear cookie.all), "cookie:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(cookie:manage),
          commands: %w(cookie.get cookie.set cookie.delete cookie.clear cookie.all),
          ipc: ipc,
        )
      end

      # `cookie.get` parses its *url* argument and returns `{"cookies" => [...]}`.
      # `cookie.set` accepts a JSON object describing the cookie. `cookie.delete`
      # takes name, domain, and path positionally. `cookie.clear` empties the
      # store. `cookie.all` returns a hash keyed by host with cookie arrays.
      def initialize_plugin(context : Plugin::Context) : Nil
        cs = Features::CookieStore.new
        @store = cs

        context.command "cookie.get", String do |url|
          uri = URI.parse(url)
          cookies = cs.get(uri)
          {"cookies" => cookies.map { |cookie| cookie_to_json(cookie) }}
        end

        context.command "cookie.set", JSON::Any do |json|
          obj = json.as_h
          cookie = Features::Cookie.new(
            name: obj["name"].as_s,
            value: obj["value"].as_s,
            domain: obj["domain"]?.try(&.as_s) || "",
            path: obj["path"]?.try(&.as_s) || "/",
            secure: obj["secure"]?.try(&.as_bool) || false,
            http_only: obj["http_only"]?.try(&.as_bool) || false,
            same_site: obj["same_site"]?.try(&.as_s) || "Lax",
          )
          cs.set(cookie)
          {"success" => true}
        end

        context.command "cookie.delete", String, String, String do |name, domain, path|
          cs.delete(name, domain, path)
          {"success" => true}
        end

        context.command "cookie.clear" do
          cs.clear
          {"success" => true}
        end

        context.command "cookie.all" do
          all = cs.all_cookies
          result = {} of String => Array(Hash(String, JSON::Any))
          all.each do |host, cookies|
            result[host] = cookies.map { |cookie| cookie_to_json(cookie) }
          end
          result
        end
      end

      # :nodoc:
      private def cookie_to_json(cookie : Features::Cookie) : Hash(String, JSON::Any)
        {
          "name"      => JSON::Any.new(cookie.name),
          "value"     => JSON::Any.new(cookie.value),
          "domain"    => JSON::Any.new(cookie.domain),
          "path"      => JSON::Any.new(cookie.path),
          "secure"    => JSON::Any.new(cookie.secure?),
          "http_only" => JSON::Any.new(cookie.http_only?),
          "same_site" => JSON::Any.new(cookie.same_site),
          "expires"   => cookie.expires.try { |e| JSON::Any.new(e.to_unix) } || JSON::Any.new(nil),
        }
      end
    end
  end
end
