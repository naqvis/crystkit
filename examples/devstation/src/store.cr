# DevStation in-memory store — all app state lives here in memory.
# Non-persistent by design: data resets on restart. The structs mirror the
# app's data model and the to_hash methods produce the exact JSON key shapes
# the frontend consumes.
module DevStation
  class Store
    # ── Notes ─────────────────────────────────────────────────────────────
    struct Note
      property id : Int64
      property title : String
      property content : String
      property color : String
      property archived : Int64
      property created_at : String
      property updated_at : String

      def initialize(@id, @title = "", @content = "", @color = "#3b82f6",
                     @archived = 0_i64, @created_at = "", @updated_at = "")
      end

      def to_hash
        {
          "id"         => id,
          "title"      => title,
          "content"    => content,
          "color"      => color,
          "archived"   => archived,
          "created_at" => created_at,
          "updated_at" => updated_at,
        }
      end

      def to_list_hash
        {
          "id"         => id,
          "title"      => title,
          "color"      => color,
          "archived"   => archived,
          "created_at" => created_at,
          "updated_at" => updated_at,
        }
      end
    end

    # ── Snippets ──────────────────────────────────────────────────────────
    struct Snippet
      property id : Int64
      property title : String
      property language : String
      property content : String
      property tags : String
      property pinned : Int64
      property created_at : String
      property updated_at : String

      def initialize(@id, @title = "", @language = "plaintext", @content = "", @tags = "",
                     @pinned = 0_i64, @created_at = "", @updated_at = "")
      end

      def to_hash
        {
          "id"         => id,
          "title"      => title,
          "language"   => language,
          "content"    => content,
          "tags"       => tags,
          "pinned"     => pinned,
          "created_at" => created_at,
          "updated_at" => updated_at,
        }
      end

      def to_list_hash
        {
          "id"         => id,
          "title"      => title,
          "language"   => language,
          "tags"       => tags,
          "pinned"     => pinned,
          "created_at" => created_at,
          "updated_at" => updated_at,
        }
      end

      def to_search_hash
        {
          "id"         => id,
          "title"      => title,
          "language"   => language,
          "tags"       => tags,
          "pinned"     => pinned,
          "created_at" => created_at,
        }
      end
    end

    # ── HTTP requests ─────────────────────────────────────────────────────
    struct HttpRequest
      property id : Int64
      property name : String
      property method : String
      property url : String
      property headers : String
      property body : String
      property collection : String
      property created_at : String

      def initialize(@id, @name = "", @method = "GET", @url = "", @headers = "{}",
                     @body = "", @collection = "History", @created_at = "")
      end

      def to_list_hash
        {
          "id"         => id,
          "name"       => name,
          "method"     => method,
          "url"        => url,
          "collection" => collection,
          "created_at" => created_at,
        }
      end

      def to_detail_hash
        {
          "id"         => id,
          "name"       => name,
          "method"     => method,
          "url"        => url,
          "headers"    => headers,
          "body"       => body,
          "collection" => collection,
        }
      end

      def to_recent_hash(status : Int64?, duration_ms : Int64?, responded_at : String?)
        {
          "id"           => id,
          "name"         => name,
          "method"       => method,
          "url"          => url,
          "collection"   => collection,
          "status"       => status,
          "duration_ms"  => duration_ms,
          "responded_at" => responded_at,
        }
      end
    end

    # ── HTTP responses ────────────────────────────────────────────────────
    struct HttpResponse
      property id : Int64
      property request_id : Int64
      property status : Int64
      property headers : String
      property body : String
      property duration_ms : Int64
      property size_bytes : Int64
      property responded_at : String

      def initialize(@id, @request_id, @status = 0_i64, @headers = "{}", @body = "",
                     @duration_ms = 0_i64, @size_bytes = 0_i64, @responded_at = "")
      end

      def to_hash
        {
          "id"           => id,
          "request_id"   => request_id,
          "status"       => status,
          "headers"      => headers,
          "body"         => body,
          "duration_ms"  => duration_ms,
          "size_bytes"   => size_bytes,
          "responded_at" => responded_at,
        }
      end

      def to_list_hash
        {
          "id"           => id,
          "status"       => status,
          "duration_ms"  => duration_ms,
          "size_bytes"   => size_bytes,
          "responded_at" => responded_at,
        }
      end
    end

    # ── Terminal command history ──────────────────────────────────────────
    struct CommandHistory
      property id : Int64
      property command : String
      property exit_code : Int64?
      property duration_ms : Int64?
      property ran_at : String

      def initialize(@id, @command = "", @exit_code = nil, @duration_ms = nil, @ran_at = "")
      end

      def to_hash
        {
          "id"          => id,
          "command"     => command,
          "exit_code"   => exit_code,
          "duration_ms" => duration_ms,
          "ran_at"      => ran_at,
        }
      end
    end

    # ── State ─────────────────────────────────────────────────────────────
    @snippets = [] of Snippet
    @http_requests = [] of HttpRequest
    @http_responses = [] of HttpResponse
    @command_history = [] of CommandHistory
    @notes = [] of Note
    @next_snippet_id = 1_i64
    @next_request_id = 1_i64
    @next_response_id = 1_i64
    @next_history_id = 1_i64
    @next_note_id = 1_i64
    @storage_dir : Path

    def self.open(storage_dir : Path) : Store
      new(storage_dir)
    end

    def initialize(@storage_dir : Path)
    end

    def close : Nil
    end

    private def now : String
      Time.utc.to_s("%Y-%m-%d %H:%M:%S")
    end

    # ── Notes ─────────────────────────────────────────────────────────────
    def create_note(title : String, content : String, color : String) : Hash(String, String | Int64)
      note = Note.new(
        id: @next_note_id,
        title: title,
        content: content,
        color: color.empty? ? "#3b82f6" : color,
        created_at: now,
        updated_at: now,
      )
      @next_note_id += 1
      @notes << note
      note.to_hash
    end

    def update_note(id : Int64, title : String, content : String, color : String) : Hash(String, String | Int64)?
      note = @notes.find { |n| n.id == id }
      return nil unless note
      note.title = title
      note.content = content
      note.color = color
      note.updated_at = now
      note.to_hash
    end

    def delete_note(id : Int64) : Nil
      @notes.reject! { |n| n.id == id }
    end

    def toggle_note_archive(id : Int64) : Bool
      note = @notes.find { |n| n.id == id }
      return false unless note
      note.archived = note.archived == 1_i64 ? 0_i64 : 1_i64
      note.updated_at = now
      note.archived == 1_i64
    end

    def list_notes(include_archived : Bool) : Array(Hash(String, String | Int64))
      notes = include_archived ? @notes : @notes.select { |n| n.archived == 0_i64 }
      notes.sort { |a, b|
        c = a.archived <=> b.archived
        c == 0 ? (b.updated_at <=> a.updated_at) : c
      }.map(&.to_list_hash)
    end

    def get_note(id : Int64) : Hash(String, String | Int64)?
      @notes.find { |n| n.id == id }.try(&.to_hash)
    end

    def search_notes(query : String) : Array(Hash(String, String | Int64))
      q = query.strip
      matches = if q.empty?
                  @notes.select { |n| n.archived == 0_i64 }
                else
                  ql = q.downcase
                  @notes.select { |n| n.title.downcase.includes?(ql) || n.content.downcase.includes?(ql) }
                end
      matches.sort { |a, b| b.updated_at <=> a.updated_at }
        .first(50)
        .map(&.to_list_hash)
    end

    def note_stats : Hash(String, Int64)
      {
        "total"    => @notes.count { |n| n.archived == 0_i64 }.to_i64,
        "archived" => @notes.count { |n| n.archived == 1_i64 }.to_i64,
      }
    end

    # ── Snippets ──────────────────────────────────────────────────────────
    def create_snippet(title : String, language : String, content : String, tags : String) : Hash(String, String | Int64)
      snippet = Snippet.new(
        id: @next_snippet_id,
        title: title,
        language: language,
        content: content,
        tags: tags,
        created_at: now,
        updated_at: now,
      )
      @next_snippet_id += 1
      @snippets << snippet
      snippet.to_hash
    end

    def update_snippet(id : Int64, title : String, language : String, content : String, tags : String) : Hash(String, String | Int64)?
      snippet = @snippets.find { |s| s.id == id }
      return nil unless snippet
      snippet.title = title
      snippet.language = language
      snippet.content = content
      snippet.tags = tags
      snippet.updated_at = now
      snippet.to_hash
    end

    def delete_snippet(id : Int64) : Nil
      @snippets.reject! { |s| s.id == id }
    end

    def toggle_snippet_pin(id : Int64) : Bool
      snippet = @snippets.find { |s| s.id == id }
      return false unless snippet
      snippet.pinned = snippet.pinned == 1_i64 ? 0_i64 : 1_i64
      snippet.updated_at = now
      snippet.pinned == 1_i64
    end

    def list_snippets(language : String) : Array(Hash(String, String | Int64))
      snippets = language.empty? ? @snippets : @snippets.select { |s| s.language == language }
      snippets.sort { |a, b|
        c = b.pinned <=> a.pinned
        c == 0 ? (b.updated_at <=> a.updated_at) : c
      }.map(&.to_list_hash)
    end

    def get_snippet(id : Int64) : Hash(String, String | Int64)?
      @snippets.find { |s| s.id == id }.try(&.to_hash)
    end

    def search_snippets(query : String) : Array(Hash(String, String | Int64))
      q = query.strip
      matches = if q.empty?
                  @snippets
                else
                  ql = q.downcase
                  @snippets.select { |s|
                    s.title.downcase.includes?(ql) ||
                      s.content.downcase.includes?(ql) ||
                      s.tags.downcase.includes?(ql)
                  }
                end
      matches.sort { |a, b| b.updated_at <=> a.updated_at }
        .first(50)
        .map(&.to_search_hash)
    end

    def snippet_languages : Array(String)
      @snippets.map(&.language).uniq.sort
    end

    def import_snippet(title : String, language : String, content : String) : Hash(String, String | Int64)
      create_snippet(title, language, content, "")
    end

    def snippet_stats : Hash(String, Int64 | Array(Hash(String, String | Int64)))
      by_lang = Hash(String, Int64).new(0_i64)
      @snippets.each { |s| by_lang[s.language] += 1_i64 }
      {
        "total"   => @snippets.size.to_i64,
        "pinned"  => @snippets.count { |s| s.pinned == 1_i64 }.to_i64,
        "by_lang" => by_lang.to_a.sort_by { |entry| -entry[1] }.map { |lang, cnt| {"language" => lang, "cnt" => cnt} },
      }
    end

    # ── HTTP client ───────────────────────────────────────────────────────
    def save_request(method : String, url : String, headers : String, body : String, name : String = "", collection : String = "History") : Int64
      req = HttpRequest.new(
        id: @next_request_id,
        name: name,
        method: method,
        url: url,
        headers: headers,
        body: body,
        collection: collection,
        created_at: now,
      )
      @next_request_id += 1
      @http_requests << req
      req.id
    end

    def save_response(request_id : Int64, status : Int32, body : String, duration_ms : Int64, size_bytes : Int64) : Nil
      resp = HttpResponse.new(
        id: @next_response_id,
        request_id: request_id,
        status: status.to_i64,
        body: body,
        duration_ms: duration_ms,
        size_bytes: size_bytes,
        responded_at: now,
      )
      @next_response_id += 1
      @http_responses << resp
    end

    def list_requests(collection : String) : Array(Hash(String, String | Int64))
      requests = collection.empty? ? @http_requests : @http_requests.select { |r| r.collection == collection }
      requests.sort_by { |r| {r.collection, r.name} }.map(&.to_list_hash)
    end

    def get_request(id : Int64) : Hash(String, String | Int64)?
      @http_requests.find { |r| r.id == id }.try(&.to_detail_hash)
    end

    def delete_request(id : Int64) : Nil
      @http_responses.reject! { |r| r.request_id == id }
      @http_requests.reject! { |r| r.id == id }
    end

    def response_history(request_id : Int64, limit : Int32) : Array(Hash(String, String | Int64))
      @http_responses
        .select { |r| r.request_id == request_id }
        .sort { |a, b| b.id <=> a.id }
        .first(limit > 0 ? limit : 20)
        .map(&.to_list_hash)
    end

    def get_response(id : Int64) : Hash(String, String | Int64)?
      @http_responses.find { |r| r.id == id }.try(&.to_hash)
    end

    def collections : Array(String)
      @http_requests.map(&.collection).uniq.sort
    end

    def recent_requests(limit : Int32) : Array(Hash(String, String | Int64 | Nil))
      latest = Hash(Int64, HttpResponse).new
      @http_responses.each { |r| latest[r.request_id] = r }
      @http_requests
        .sort { |a, b| b.id <=> a.id }
        .first(limit > 0 ? limit : 20)
        .map do |req|
          resp = latest[req.id]?
          req.to_recent_hash(resp.try(&.status), resp.try(&.duration_ms), resp.try(&.responded_at))
        end
    end

    # ── Terminal command history ──────────────────────────────────────────
    def record_command(command : String, exit_code : Int64? = nil, duration_ms : Int64? = nil) : Int64
      entry = CommandHistory.new(
        id: @next_history_id,
        command: command,
        exit_code: exit_code,
        duration_ms: duration_ms,
        ran_at: now,
      )
      @next_history_id += 1
      @command_history << entry
      entry.id
    end

    def update_command_exit(id : Int64, exit_code : Int64?, duration_ms : Int64?) : Nil
      entry = @command_history.find { |h| h.id == id }
      return unless entry
      entry.exit_code = exit_code
      entry.duration_ms = duration_ms
    end

    def history(limit : Int32) : Array(Hash(String, String | Int64 | Nil))
      @command_history
        .sort { |a, b| b.id <=> a.id }
        .first(limit > 0 ? limit : 100)
        .map(&.to_hash)
    end

    def clear_history : Nil
      @command_history.clear
    end
  end
end
