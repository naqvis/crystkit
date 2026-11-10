require "json"
require "log"
require "../core/errors"

module CrystKit
  module Security
    # Permission levels for scoped path access.
    #
    # `Write` is a superset of `Read` — a persisted `Write` scope satisfies
    # both `Write` and `Read` requests.
    enum Permission
      # Read access: the path may be opened for reading.
      Read
      # Write access: the path may be opened for writing.
      # Implies read access — a `Write` grant also satisfies `Read` checks.
      Write
      # Execute access: the path may be executed (e.g. as a program).
      Execute
    end

    # A persisted scope entry associating a path with a permission.
    #
    # Instances are serialized to JSON and keyed by path string. The
    # `#permission` getter exposes the typed `Permission` value directly.
    struct PersistedScope
      include JSON::Serializable

      # The canonical string form of the path this scope applies to.
      getter path : String

      # The permission this scope grants, as a typed `Permission` value.
      getter permission : Permission

      # UTC timestamp at which the scope was granted.
      getter granted_at : Time

      # Optional UTC timestamp after which the scope is considered expired.
      # `nil` means the scope does not expire.
      getter expires_at : Time?

      # Creates a persisted scope for *path* with *permission* and an
      # optional *expires_at*. `granted_at` is set to the current UTC time.
      def initialize(path : Path, permission : Permission, expires_at : Time? = nil)
        @path = path.to_s
        @permission = permission
        @granted_at = Time.utc
        @expires_at = expires_at
      end

      # Returns `true` if `expires_at` is set and the current UTC time is
      # past it. Scopes without an expiry always return `false`.
      def expired? : Bool
        if exp = @expires_at
          Time.utc > exp
        else
          false
        end
      end
    end

    # Manages persisted path-based permission scopes.
    #
    # Records, per path, one or more `Permission` levels that have been
    # granted, and persists those records to disk as JSON so they survive
    # application restarts. Multiple permissions can coexist for the same
    # path (e.g. both `Write` and `Execute` on `/`); persisting the same
    # permission again replaces just that entry.
    #
    # Lookups use prefix semantics: a request for `/home/alice/docs/x.txt`
    # matches any persisted scope whose path is a prefix of the request
    # (e.g. `/home/alice/docs`), and the longest matching prefix wins.
    #
    # When constructed with a *storage_path*, the manager loads scopes from
    # disk at construction time and writes back on every mutating call.
    # Without a storage path the manager is in-memory only.
    #
    # ```
    # mgr = ScopeManager.new(Path["~/.config/myapp/scopes.json"].expand(home: true))
    # mgr.persist(Path["~/Documents"].expand(home: true), Permission::Write)
    # mgr.require!(Path["~/Documents/notes.txt"].expand(home: true), Permission::Read)
    # ```
    class ScopeManager
      # :nodoc:
      @scopes : Hash(String, Array(PersistedScope))
      # :nodoc:
      @storage_path : Path?
      # :nodoc:
      @mutex = Mutex.new

      # Creates a new scope manager, optionally persisting to *storage_path*.
      #
      # When *storage_path* points to an existing file, the manager loads
      # its contents immediately and drops any expired entries. A missing
      # file is treated as an empty scope set; a corrupt file is logged at
      # warn level and reset to empty. Pass `nil` (the default) for a
      # purely in-memory manager.
      def initialize(@storage_path = nil)
        @scopes = Hash(String, Array(PersistedScope)).new
        load_from_disk if @storage_path
      end

      # Persists *permission* for *path*, replacing any existing scope with
      # the same permission for that path (other permissions on the same
      # path are preserved). Rejects empty paths and path traversal
      # sequences such as `../`. *expires_at*, when provided, marks the
      # scope as temporary.
      #
      # Raises `Core::SecurityError` (code `INVALID_PATH` or
      # `PATH_TRAVERSAL`) on malformed paths.
      def persist(path : String, permission : Permission, expires_at : Time? = nil) : Nil
        @mutex.synchronize { persist_impl(scope_path(path), permission, expires_at) }
      end

      def persist(path : Path, permission : Permission, expires_at : Time? = nil) : Nil
        @mutex.synchronize { persist_impl(path, permission, expires_at) }
      end

      private def persist_impl(path : Path, permission : Permission, expires_at : Time? = nil) : Nil
        validate_path!(path)
        key = path.to_s
        scope = PersistedScope.new(path, permission, expires_at)
        existing = @scopes[key]?
        if existing
          # Replace any scope with the same permission; keep the rest.
          @scopes[key] = existing.reject(&.permission.==(permission)) << scope
        else
          @scopes[key] = [scope]
        end
        save_to_disk
      end

      # Returns `true` if *path* has a non-expired persisted permission that
      # satisfies *permission*. Uses prefix matching (longest matching
      # prefix wins). A `Write` scope satisfies both `Write` and `Read`
      # requests; `Execute` and `Read` satisfy only their own level.
      #
      # Returns `false` — never raises — when no scope matches. Use
      # `#require!` for the raising variant.
      def validate(path : String, permission : Permission) : Bool
        @mutex.synchronize { validate_impl(scope_path(path), permission) }
      end

      def validate(path : Path, permission : Permission) : Bool
        @mutex.synchronize { validate_impl(path, permission) }
      end

      private def validate_impl(path : Path, permission : Permission) : Bool
        target = path.expand(home: true)
        @scopes.each_value do |scopes|
          scopes.each do |scope|
            next if scope.expired?
            next unless descendant_or_same?(target, Path[scope.path].expand(home: true))
            case permission
            in .read?
              return true if scope.permission.read? || scope.permission.write?
            in .write?
              return true if scope.permission.write?
            in .execute?
              return true if scope.permission.execute?
            end
          end
        end
        false
      end

      # Requires *path* to have a persisted permission satisfying *permission*,
      # raising `Core::SecurityError` (code `SCOPE_DENIED`) otherwise.
      # The path is expanded with `expand(home: true)` before the lookup.
      def require!(path : String, permission : Permission) : Nil
        require!(scope_path(path), permission)
      end

      def require!(path : Path, permission : Permission) : Nil
        return if validate(path, permission)

        raise Core::SecurityError.new(
          "Missing scope: #{permission} for #{path.expand}",
          code: "SCOPE_DENIED",
        )
      end

      # Returns `true` if any non-expired permission exists for *path*, across
      # all permission levels. Cheaper than `#validate` when the caller
      # only needs to know whether the path is managed at all.
      def has_scope?(path : String) : Bool
        @mutex.synchronize { has_scope_impl(scope_path(path)) }
      end

      def has_scope?(path : Path) : Bool
        @mutex.synchronize { has_scope_impl(path) }
      end

      private def has_scope_impl(path : Path) : Bool
        @scopes[path.to_s]?.try(&.any? { |scope| !scope.expired? }) || false
      end

      # Revokes the persisted permission for *path*. Idempotent.
      def revoke(path : String)
        @mutex.synchronize { revoke_impl(scope_path(path)) }
      end

      def revoke(path : Path)
        @mutex.synchronize { revoke_impl(path) }
      end

      private def revoke_impl(path : Path) : Nil
        @scopes.delete(path.to_s)
        save_to_disk
      end

      # Returns all non-expired persisted scopes as a fresh array. Use
      # `#cleanup_invalid` to physically remove expired entries from disk.
      def query : Array(PersistedScope)
        @mutex.synchronize { @scopes.values.flatten.reject(&.expired?) }
      end

      # Removes **all** scopes from memory and disk. Call this at app startup
      # to ensure scope state is driven by the manifest and code declarations
      # rather than accumulated from previous runs.
      def clear
        @mutex.synchronize do
          @scopes.clear
          save_to_disk
        end
      end

      # Removes all expired scopes from memory and disk. Safe to call any time
      # to reclaim space.
      def cleanup_invalid
        @mutex.synchronize do
          @scopes.each_value { |scopes| scopes.reject!(&.expired?) }
          @scopes.reject! { |_, scopes| scopes.empty? }
          save_to_disk
        end
      end

      # :nodoc:
      private def scope_path(path : String) : Path
        Path[path == "*" ? "/" : path]
      end

      # :nodoc:
      private def validate_path!(path : Path)
        str = path.to_s
        raise Core::SecurityError.new(
          "Invalid path: path cannot be empty",
          code: "INVALID_PATH"
        ) if str.empty?

        # Prevent path traversal: expand the path (which lexically resolves
        # `..`) and reject if any `..` survives expansion — that signals a
        # non-normalizable traversal attempt.
        expanded = path.expand(home: true)
        if expanded.to_s.includes?("..")
          raise Core::SecurityError.new(
            "Invalid path: path traversal not allowed in '#{str}'",
            code: "PATH_TRAVERSAL"
          )
        end
      end

      # :nodoc:
      private def descendant_or_same?(target : Path, root : Path) : Bool
        target_parts = target.expand(home: true).to_s.gsub('\\', '/').split('/').reject(&.empty?)
        root_parts = root.expand(home: true).to_s.gsub('\\', '/').split('/').reject(&.empty?)
        return false if root_parts.size > target_parts.size
        root_parts.each_with_index do |part, i|
          return false unless part == target_parts[i]
        end
        true
      end

      # :nodoc:
      private def save_to_disk
        path = @storage_path
        return unless path

        begin
          Dir.mkdir_p(path.parent.to_s)
          File.write(path.to_s, @scopes.to_json)
        rescue ex
          Log.error { "ScopeManager: failed to save scopes to #{path}: #{ex.message}" }
        end
      end

      # :nodoc:
      private def load_from_disk
        path = @storage_path
        return unless path
        return unless File.exists?(path.to_s)

        begin
          content = File.read(path.to_s)
          parsed = Hash(String, Array(PersistedScope)).from_json(content)
          @scopes = parsed
          cleanup_invalid
        rescue ex
          Log.warn { "ScopeManager: failed to load scopes from #{path}: #{ex.message}" }
          @scopes = Hash(String, Array(PersistedScope)).new
        end
      end
    end
  end
end
