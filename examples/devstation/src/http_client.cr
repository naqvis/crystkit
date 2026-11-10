require "../../../src/app/app"
require "../../../src/features/http"

# HTTP Client module — a full API client with collections, history, and
# variable interpolation. Scoped to all https:// by capabilities.
# History is kept in the in-memory DevStation::Store (non-persistent).
module DevStation::HttpClient
  extend self

  def setup(app : CrystKit::App, store : DevStation::Store) : Nil
    http = CrystKit::Features::HTTPClient.new(app.security)

    # ── Send a request ────────────────────────────────────────────────────
    app.async "http_client.send", String, String, JSON::Any, String, timeout: 60.seconds do |method, url, headers_json, body, _cancel|
      hdrs = {} of String => String
      if obj = headers_json.as_h?
        obj.each { |k, v| hdrs[k] = v.as_s? || v.to_s }
      end

      opts = CrystKit::Features::RequestOptions.new(headers: hdrs)
      started = Time.instant

      response = case method.upcase
                 when "GET"    then http.get(url, opts)
                 when "POST"   then http.post(url, body, opts)
                 when "PUT"    then http.put(url, body, opts)
                 when "PATCH"  then http.patch(url, body, opts)
                 when "DELETE" then http.delete(url, opts)
                 else               raise "Unsupported method: #{method}"
                 end

      ms = (Time.instant - started).total_milliseconds.to_i
      size_bytes = response.text.bytesize

      # Auto-save request + response to history
      req_id = store.save_request(method, url, headers_json.to_json, body)
      store.save_response(req_id, response.status, response.text, ms.to_i64, size_bytes.to_i64)

      # Try to parse response body as JSON for pretty display
      parsed_body = begin
        JSON.parse(response.text)
        response.text # keep as string, frontend will parse
      rescue
        response.text
      end

      resp_headers = {} of String => String
      response.headers.each { |k, v| resp_headers[k] = v.join(", ") }

      {
        "status"      => response.status,
        "body"        => parsed_body,
        "headers"     => resp_headers,
        "duration_ms" => ms,
        "size_bytes"  => size_bytes,
        "success"     => response.success?,
        "request_id"  => req_id,
      }
    end

    # ── Save request to collection ────────────────────────────────────────
    app.async "http_client.save_request", String, String, String, JSON::Any, String, String do |name, method, url, headers_json, body, collection, _cancel|
      id = store.save_request(method, url, headers_json.to_json, body, name, collection)
      {"id" => id}
    end

    # ── List saved requests ───────────────────────────────────────────────
    app.async "http_client.list_requests", String do |collection, _cancel|
      store.list_requests(collection)
    end

    # ── Get a saved request with full headers/body ────────────────────────
    app.async "http_client.get_request", Int32 do |id, _cancel|
      store.get_request(id.to_i64)
    end

    # ── Delete a request ──────────────────────────────────────────────────
    app.async "http_client.delete_request", Int32 do |id, _cancel|
      store.delete_request(id.to_i64)
      "ok"
    end

    # ── Response history for a request ────────────────────────────────────
    app.async "http_client.response_history", Int32, Int32 do |request_id, limit, _cancel|
      store.response_history(request_id.to_i64, limit)
    end

    # ── Full response body (by response id) ───────────────────────────────
    app.async "http_client.get_response", Int32 do |id, _cancel|
      store.get_response(id.to_i64)
    end

    # ── List collections ──────────────────────────────────────────────────
    app.async "http_client.collections" do
      store.collections
    end

    # ── Recent history (last N requests with their latest response) ────────
    app.async "http_client.recent", Int32 do |limit, _cancel|
      store.recent_requests(limit)
    end
  end
end
