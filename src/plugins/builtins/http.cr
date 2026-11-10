require "../base"
require "../../features/http"

module CrystKit
  module Plugins
    # HTTP client plugin letting the frontend issue outbound HTTP requests
    # subject to per-URL capability scoping.
    #
    # Each command is authorized against the `http:request` capability bound to
    # the request's `url`, so applications can restrict the frontend to an
    # allowlist of origins.
    #
    # Registers IPC commands:
    #   http:get, http:post, http:put, http:delete, http:patch
    #
    # Required capability: http:request (per-URL scoped)
    class HTTP < Plugin::Base
      # Exposes HTTP fetch capabilities to the frontend.
      Log = ::Log.for(self)

      # IPC payload for every HTTP command.
      #
      # *url* is the request target and the resource used for capability
      # scoping. *headers* is an optional header map applied to the request.
      # *body* is an optional JSON value; strings are sent verbatim, any other
      # JSON value is serialized with `to_json`.
      struct Request
        include JSON::Serializable
        getter url : String
        getter headers : Hash(String, String) = {} of String => String
        getter body : JSON::Any?
      end

      getter! client

      def identifier : String
        "http"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
        %w(http.get http.delete http.post http.put http.patch).each do |command|
          ipc.resource(command, "http:request", "url")
        end

        Plugin::Metadata.new(
          identifier,
          capabilities: ["http:request"],
          commands: %w(http.get http.delete http.post http.put http.patch),
          ipc: ipc,
        )
      end

      # Each command returns `{status, body, success}` from the underlying
      # response.
      def initialize_plugin(context : Plugin::Context) : Nil
        @client = c = Features::HTTPClient.new(context.security)

        context.command "http.get", Request do |request|
          response_to_json(c.get(request.url, build_options(request.headers)))
        end

        context.command "http.delete", Request do |request|
          response_to_json(c.delete(request.url, build_options(request.headers)))
        end

        context.command "http.post", Request do |request|
          response_to_json(c.post(request.url, body_to_string(request.body), build_options(request.headers)))
        end

        context.command "http.put", Request do |request|
          response_to_json(c.put(request.url, body_to_string(request.body), build_options(request.headers)))
        end

        context.command "http.patch", Request do |request|
          response_to_json(c.patch(request.url, body_to_string(request.body), build_options(request.headers)))
        end
      end

      # :nodoc: Builds `Features::RequestOptions` from the request header map.
      private def build_options(headers : Hash(String, String)) : Features::RequestOptions
        validate_headers(headers)
        Features::RequestOptions.new(headers: headers)
      end

      # :nodoc: Rejects header keys/values containing CR or LF to prevent
      # HTTP header injection from untrusted frontend payloads.
      private def validate_headers(headers : Hash(String, String)) : Nil
        headers.each do |k, v|
          if k.includes?('\r') || k.includes?('\n') || v.includes?('\r') || v.includes?('\n')
            raise Core::Error.new("Header injection detected in '#{k}'", code: "HEADER_INJECTION")
          end
        end
      end

      # :nodoc: Serializes the optional request body to a string. Strings are
      # sent verbatim; any other JSON value is serialized with `to_json`. A
      # nil body yields an empty string.
      private def body_to_string(body : JSON::Any?) : String
        return "" unless body
        body.as_s? || body.to_json
      end

      # :nodoc: Shapes an `Features::HTTPResponse` into the JSON hash returned
      # to the frontend.
      private def response_to_json(response : Features::HTTPResponse)
        {
          "status"  => response.status,
          "body"    => response.text,
          "success" => response.success?,
        }
      end
    end
  end
end
