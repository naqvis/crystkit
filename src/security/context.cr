require "./capability"
require "./scope"
require "./scopes/loader"

module CrystKit
  # The security subsystem of CrystKit.
  #
  # Provides a capability-based access control model with per-window grants,
  # persisted path scopes, manifest-driven authority, and runtime permission
  # prompting. See `Context` for the composition root.
  module Security
    # The composition root for CrystKit's security subsystem.
    #
    # Threads together three layers of access control:
    #
    # 1. *Capabilities* — coarse-grained feature toggles (e.g. `fs:read`,
    #    `http:write`) with per-window isolation and runtime prompting.
    # 2. *Scopes* — fine-grained, persisted path permissions (e.g.
    #    read/write access to specific directories).
    # 3. *Resource scopes* — in-memory prefix matchers that gate which
    #    concrete resources a capability may touch (e.g. which HTTP origins,
    #    which process names).
    #
    # When constructed with a *window_id*, all `require!`-style
    # calls enforce that window's restrictions. The id is set at
    # construction time and cannot be changed afterwards.
    #
    # ```
    # ctx = Security::Context.new(window_id: "main")
    # ctx.load_manifest(Path["~/.config/myapp/capabilities.json"].expand(home: true))
    # ctx.require!("fs:read", "/etc/hosts")
    # ```
    class Context
      Log = ::Log.for(self)

      # The capability system for this context.
      getter capabilities : CapabilitySystem

      # The scope manager for this context.
      getter scopes : ScopeManager

      # The resource scopes loaded from the manifest, keyed by capability
      # prefix (e.g. `"fs"`, `"http"`, `"process"`). Empty until
      # `#load_manifest` is invoked.
      getter resource_scopes : Hash(String, Scopes::BaseScope)

      # The window id this context is bound to, or `nil` if unbound.
      #
      # When set, `#require!` enforces that window's capability restrictions.
      getter window_id : String?

      # Creates a new security context with optional injectable subsystems.
      #
      # All arguments default to fresh, empty instances. The optional
      # arguments are primarily useful for tests. The *window_id* binds the
      # context to a specific window so that subsequent `#require!` calls
      # enforce per-window capability restrictions.
      def initialize(
        @capabilities = CapabilitySystem.new,
        @scopes = ScopeManager.new,
        @resource_scopes = {} of String => Scopes::BaseScope,
        @window_id = nil,
      )
      end

      # Raises `Core::SecurityError` (code `CAPABILITY_DENIED`) unless *capability*
      # is currently granted to this context's window (if bound).
      #
      # *capability* is a plain identifier such as `"fs:read"`.
      # *resource* is an optional concrete resource string used for scope
      # matching (e.g. a file path or URL).
      # *context* is an optional human-readable trace string recorded on
      # violation audit entries.
      def require!(capability : String, resource : String? = nil, context : String? = nil) : Nil
        @capabilities.require!(capability, resource, context, @window_id)
      end

      # Requires both a capability and a persisted path permission in one call.
      #
      # *capability* (e.g. `fs:read`, `fs:write`) must be granted to the
      # active window, and the *path* must have a non-expired persisted
      # `Permission` grant that satisfies *permission*. The *path* is
      # expanded with `expand(home: true)` before both checks.
      #
      # Raises `Core::SecurityError` with code `CAPABILITY_DENIED` if the
      # capability is missing, or `SCOPE_DENIED` if the path scope is missing
      # or insufficient.
      #
      # ```
      # ctx.require_path!("fs:write", Path["~/Documents/notes.txt"], Permission::Write)
      # ```
      def require_path!(capability : String, path : Path, permission : Permission) : Nil
        expanded = path.expand(home: true)
        require!(capability, expanded.to_s)
        @scopes.require!(expanded, permission)
      end

      # Requires both a capability and a matching resource scope in one call.
      #
      # For resources addressed by string prefixes (HTTP origins, process
      # names, etc.) rather than filesystem paths. *capability* must be granted
      # to the active window, and *resource* must be allowed by the
      # `Scopes::BaseScope` registered for the capability's prefix (the portion
      # of *capability* before the first `:`, e.g. the `fs` in `fs:read`).
      #
      # Raises `Core::SecurityError` (code `CAPABILITY_DENIED`) if the
      # capability is missing, or `SCOPE_DENIED` if no matching prefix scope
      # exists or the registered scope returns `false` for *resource*.
      #
      # ```
      # ctx.require_resource!("http:get", "https://api.example.com/users")
      # ```
      def require_resource!(capability : String, resource : String) : Nil
        require!(capability, resource)
        prefix = capability.partition(':')[0]
        scope = @resource_scopes[prefix]?
        raise Core::SecurityError.new(
          "Resource scope denied: no scope registered for prefix '#{prefix}' (required by #{capability})",
          code: "SCOPE_DENIED"
        ) unless scope
        raise Core::SecurityError.new(
          "Resource scope denied: #{capability} for #{resource}",
          code: "SCOPE_DENIED"
        ) unless scope.allows?(resource)
      end

      # Loads the security manifest at *path* and reconciles it with the
      # persisted scopes.
      #
      # Validates and auto-grants every listed capability, applies the
      # per-window allow-lists, instantiates one `Scopes::BaseScope` per
      # capability prefix declared in the `scopes` section, and mirrors `fs`
      # scope paths into the persisted `ScopeManager` (with `Permission::Write`
      # if any write/delete capability is declared, otherwise `Permission::Read`).
      #
      # When `process:spawn` or `shell:execute` is declared, each `fs` scope
      # path is additionally granted `Permission::Execute` so that
      # `ProcessManager#spawn` / `ShellExecutor#execute` can use them as a
      # working directory (both gate the cwd with `require_path!(...,
      # Permission::Execute)`).
      #
      # Returns the loaded `Manifest` so callers can log or inspect it
      # without re-reading the file.
      #
      # Raises `Core::SecurityError` (code `MANIFEST_NOT_FOUND`) if the file
      # does not exist, or `Core::ValidationError` if the manifest fails
      # schema validation.
      def load_manifest(path : Path) : Manifest
        manifest = @capabilities.load_manifest(path)

        @resource_scopes = Scopes::Loader.load(manifest.scopes)

        if fs_scope = @resource_scopes["fs"]?
          if fs_scope.is_a?(Scopes::FsScope)
            has_write = manifest.capabilities.any? { |cap| cap == "fs:write" || cap == "fs:delete" }
            permission = has_write ? Permission::Write : Permission::Read
            needs_execute = manifest.capabilities.any? { |cap| cap == "process:spawn" || cap == "shell:execute" }
            fs_scope.paths.each do |p|
              if p == "*"
                Log.warn { "Manifest grants filesystem scope '*' (root) — this allows access to the entire filesystem" }
                root = Path["/"]
                @scopes.persist(root, permission)
                @scopes.persist(root, Permission::Execute) if needs_execute
              else
                expanded = Path[p].expand(home: true)
                @scopes.persist(expanded, permission)
                @scopes.persist(expanded, Permission::Execute) if needs_execute
              end
            end
          end
        end
        manifest
      end
    end
  end
end
