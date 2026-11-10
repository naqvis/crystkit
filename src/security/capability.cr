require "json"
require "log"
require "../core/errors"
require "./manifest"
require "./permission_prompt"

module CrystKit
  module Security
    # A granted capability record with optional scope and expiry.
    #
    # Wraps a capability identifier (e.g. `"fs:read"`) with runtime metadata:
    # when it was granted, whether it expires, and what resource scope it
    # applies to. Instances are immutable; to change a grant's scope or
    # expiry, replace the entry via `CapabilitySystem#grant`.
    #
    # The *scope* field, when set, restricts the grant to resources whose
    # string form starts with the scope prefix. The *expires_at* field, when
    # set, marks the grant as temporary; expired grants are treated as
    # missing without requiring explicit revocation.
    struct CapabilityGrant
      include JSON::Serializable

      # The capability identifier this grant wraps (e.g. `"fs:read"`).
      getter name : String

      # Optional resource scope prefix. When non-nil, the grant only
      # authorizes resources whose string form starts with this prefix.
      getter scope : String?

      # The UTC timestamp at which the grant was created.
      getter granted_at : Time

      # Optional UTC timestamp after which the grant is considered expired.
      # `nil` means the grant does not expire.
      getter expires_at : Time?

      # Creates a grant for *name* with optional *scope* and *expires_at*.
      # `granted_at` is set to the current UTC time.
      def initialize(@name : String, @scope = nil, @expires_at = nil)
        @granted_at = Time.utc
      end

      # Returns `true` if `expires_at` is set and the current UTC time is
      # past it. Grants without an expiry always return `false`.
      def expired? : Bool
        if exp = @expires_at
          Time.utc > exp
        else
          false
        end
      end
    end

    # Records a denied capability access for audit purposes.
    #
    # Violations are never persisted across restarts; callers that need durable
    # audit trails should drain `CapabilitySystem#violations` periodically and
    # write them to their own sink.
    #
    # The *resource* and *context* fields carry the optional hints passed to the
    # failing `require!` call: a typical *context* value is
    # `"window:<window_id>"` or `"runtime_request_denied"`.
    struct CapabilityViolation
      include JSON::Serializable

      # The capability identifier that was required but not granted.
      getter capability : String

      # The concrete resource string associated with the failed access, if any.
      getter resource : String?

      # UTC timestamp at which the violation was recorded.
      getter timestamp : Time

      # Free-form trace string describing where the violation originated
      # (e.g. `"window:main"`, `"runtime_request_denied"`).
      getter context : String?

      # Creates a violation record for *capability* with optional *resource*
      # and *context* hints. `timestamp` is set to the current UTC time.
      def initialize(@capability : String, @resource = nil, @context = nil)
        @timestamp = Time.utc
      end
    end

    # Capability-based permission system.
    #
    # Tracks which capability identifiers (plain strings of the form
    # `"feature:verb"`, e.g. `"fs:read"`, `"http:get"`) are granted, either
    # globally or restricted per window. Child windows inherit capabilities
    # from their parent window: the effective capability set for any window
    # is the union of its own grants and every ancestor's grants.
    #
    # Runtime capability requests are supported via `#request_capability`:
    # when code needs a capability that has not been pre-granted, the
    # registered prompt handler (see `#set_prompt_handler` /
    # `#on_capability_request`) is consulted; otherwise the request is denied
    # with a secure default.
    #
    # Denied access attempts are recorded as `CapabilityViolation` entries
    # available via `#violations` for audit.
    class CapabilitySystem
      # :nodoc:
      @manifest : Manifest
      # :nodoc:
      @granted : Hash(String, CapabilityGrant)
      # :nodoc:
      @violations : Array(CapabilityViolation)
      # :nodoc:
      @window_caps : Hash(String, Array(String))
      # Maps child_window_id => parent_window_id for capability inheritance
      # :nodoc:
      @window_parents : Hash(String, String)
      # Pending runtime capability requests (Requirement 25.10 / task 35.3)
      # :nodoc:
      @pending_requests : Hash(String, CapabilityRequest)
      # Optional user-prompt handler for runtime capability requests.
      # Receives a CapabilityRequest and returns Approved or Denied.
      # :nodoc:
      @prompt_handler : Proc(CapabilityRequest, CapabilityRequestOutcome)?

      # Whether a capabilities manifest has been loaded. When `true`, plugin
      # capabilities are NOT auto-granted on registration — the manifest and
      # explicit `app.grant` calls are the sole source of authority. When
      # `false` (no manifest), plugins auto-grant their declared capabilities
      # for demo-mode convenience.
      @manifest_loaded : Bool = false

      getter? manifest_loaded : Bool

      # Creates an empty capability system.
      #
      # Use `#load_manifest` to populate it from a `capabilities.json` file,
      # or call `#grant` / `#grant_to_window` programmatically.
      def initialize
        @manifest = Manifest.new
        @granted = Hash(String, CapabilityGrant).new
        @violations = [] of CapabilityViolation
        @window_caps = Hash(String, Array(String)).new
        @window_parents = Hash(String, String).new
        @pending_requests = Hash(String, CapabilityRequest).new
        @prompt_handler = nil
      end

      # Loads capability configuration from the JSON manifest at *path*.
      #
      # Validates the manifest format before loading. Raises
      # `Core::SecurityError` (code `MANIFEST_NOT_FOUND`) if the file does
      # not exist, or `Core::ValidationError` if the manifest has format
      # errors.
      def load_manifest(path : Path) : Manifest
        unless File.exists?(path.to_s)
          raise Core::SecurityError.new(
            "Capability manifest not found: #{path}",
            code: "MANIFEST_NOT_FOUND"
          )
        end

        content = File.read(path.to_s)

        # Validate manifest format before parsing
        errors = Manifest.validate(content)
        unless errors.empty?
          raise Core::ValidationError.new(
            "Capability manifest format errors: #{errors.join("; ")}",
            field: "manifest"
          )
        end

        @manifest = Manifest.from_json(content)
        @manifest_loaded = true

        # Auto-grant all capabilities listed in the manifest
        @manifest.capabilities.each do |cap|
          @granted[cap] = CapabilityGrant.new(cap)
        end

        # Load per-window capabilities
        @window_caps = @manifest.windows.transform_values(&.dup)

        @manifest
      end

      # Returns `true` if *capability* is currently granted and not expired.
      #
      # When *resource* is supplied and the grant carries a `scope` prefix,
      # additionally requires that *resource* starts with the scope string.
      # Returns `false` — never raises — for missing, expired, or
      # out-of-scope grants. Use `#require!` for the raising variant.
      def check(capability : String, resource : String? = nil) : Bool
        cap = @granted[capability]?
        return false unless cap
        return false if cap.expired?

        # If a scope is set on the capability, validate the resource matches
        if scope = cap.scope
          if res = resource
            return res.starts_with?(scope)
          else
            return false
          end
        end

        true
      end

      # Returns `true` if *capability* is granted to *window_id*, including
      # capabilities inherited from ancestor windows.
      #
      # The capability must also be globally granted (per `#check`).
      # Returns `false` — never raises — when the window lacks the
      # capability. Use `#require_for_window!` for the raising variant.
      def check_for_window(capability : String, window_id : String, resource : String? = nil) : Bool
        return false unless check(capability, resource)
        effective_capabilities_for_window(window_id).includes?(capability)
      end

      # Requires *capability* for *window_id*, raising `SecurityError` and
      # logging a `CapabilityViolation` if the window does not have it.
      #
      # *context*, when provided, is recorded on the violation entry; when
      # `nil`, the violation context defaults to `"window:<window_id>"`.
      # Raises `Core::SecurityError` (code `CAPABILITY_DENIED`) on denial.
      def require_for_window!(capability : String, window_id : String, resource : String? = nil, context : String? = nil)
        unless check_for_window(capability, window_id, resource)
          violation = CapabilityViolation.new(capability, resource, context || "window:#{window_id}")
          audit_log(violation)
          raise Core::SecurityError.new(
            "Missing capability: #{capability} for window '#{window_id}'#{resource ? " and resource #{resource}" : ""}",
            code: "CAPABILITY_DENIED"
          )
        end
      end

      # Returns the capabilities explicitly granted to *window_id* (not
      # inherited), as a fresh array. Returns an empty array for unknown
      # window ids. Use `#grant_to_window` / `#revoke_from_window` to modify
      # the window's grants.
      def window_capabilities(window_id : String) : Array(String)
        (@window_caps[window_id]? || [] of String).dup
      end

      # Returns the effective capability set for *window_id*, including
      # capabilities inherited from ancestor windows. A capability is
      # effective if it appears in any window in the ancestor chain (union
      # semantics).
      #
      # Returns an empty array for unknown window ids.
      def effective_capabilities_for_window(window_id : String) : Array(String)
        result = Set(String).new

        current = window_id
        visited = Set(String).new

        loop do
          break if visited.includes?(current) # guard against cycles
          visited << current

          if caps = @window_caps[current]?
            caps.each { |cap| result << cap }
          end

          parent = @window_parents[current]?
          break unless parent
          current = parent
        end

        result.to_a
      end

      # Registers a parent-child window relationship for capability inheritance.
      #
      # Child windows inherit all capabilities from their parent window,
      # transitively.
      #
      # Raises `ArgumentError` if *child_window_id* equals
      # *parent_window_id*, or if registering the link would create a cycle
      # in the parent graph.
      def set_window_parent(child_window_id : String, parent_window_id : String)
        if child_window_id == parent_window_id
          raise ArgumentError.new("Window cannot be its own parent: '#{child_window_id}'")
        end

        # Detect cycles: walk up the parent chain from parent_window_id.
        # If we encounter child_window_id while walking up, adding this relationship
        # would create a cycle.
        current : String? = parent_window_id
        visited = Set(String).new
        while node = current
          if node == child_window_id
            raise ArgumentError.new(
              "Setting parent of '#{child_window_id}' to '#{parent_window_id}' would create a cycle"
            )
          end
          break if visited.includes?(node)
          visited << node
          current = @window_parents[node]?
        end

        @window_parents[child_window_id] = parent_window_id
      end

      # Removes the parent relationship for *window_id*, stopping capability
      # inheritance from that point upward. Idempotent.
      def unset_window_parent(window_id : String)
        @window_parents.delete(window_id)
      end

      # Returns the parent window id for a given window, or `nil` if none is set.
      def window_parent(window_id : String) : String?
        @window_parents[window_id]?
      end

      # Revokes *capability* from *window_id*'s allow-list. Does not revoke the
      # global grant — the capability may still be effective via inheritance
      # from an ancestor window. To remove a capability entirely use
      # `#revoke` in addition to (or instead of) this method. No-op for
      # unknown windows or capabilities.
      def revoke_from_window(capability : String, window_id : String)
        if caps = @window_caps[window_id]?
          caps.delete(capability)
          @window_caps.delete(window_id) if caps.empty?
        end
      end

      # Grants *capability* at runtime, optionally with a *scope* prefix and
      # *expires_at* expiry. Replaces any existing grant for *capability*.
      # Use `#grant_temporary` for the convenience overload that accepts a
      # `Time::Span`.
      def grant(capability : String, scope : String? = nil, expires_at : Time? = nil)
        @granted[capability] = CapabilityGrant.new(capability, scope, expires_at)
      end

      # Revokes the grant for *capability* from the global table. Does not
      # touch per-window allow-lists: a window that still lists the
      # capability will find nothing to inherit. Idempotent.
      def revoke(capability : String)
        @granted.delete(capability)
      end

      # :nodoc:
      # Grant a capability to a specific target.
      private def grant_to_target(capability : String, target_id : String, caps : Hash(String, Array(String)))
        caps[target_id] ||= [] of String
        caps[target_id] << capability unless caps[target_id].includes?(capability)
        grant(capability) unless @granted.has_key?(capability)
      end

      # Grants *capability* to *window_id*'s allow-list. Also ensures the
      # capability is granted globally if it has not been already, so the
      # window grant is meaningful. Idempotent.
      def grant_to_window(capability : String, window_id : String)
        grant_to_target(capability, window_id, @window_caps)
      end

      # Returns all currently granted (non-expired) capabilities as a fresh
      # snapshot. Expired grants are filtered out.
      def query : Array(CapabilityGrant)
        @granted.values.reject(&.expired?)
      end

      # Appends *violation* to the audit log and emits a `Log.warn` entry.
      #
      # Public API so integrators can record custom violations from layers
      # above the capability system.
      def audit_log(violation : CapabilityViolation)
        @violations << violation
        Log.warn { "Capability violation: '#{violation.capability}'" \
                   "#{violation.resource ? " for resource '#{violation.resource}'" : ""}" \
                   "#{violation.context ? " (#{violation.context})" : ""}" }
      end

      # Returns all recorded violations as a fresh array. The audit log is
      # in-memory only and is not persisted across restarts; drain this list
      # periodically if you need a durable audit trail.
      def violations : Array(CapabilityViolation)
        @violations.dup
      end

      # Returns `true` when at least one window has a non-empty capability
      # allow-list.
      def window_restrictions? : Bool
        !@window_caps.empty?
      end

      # Requires *capability*, raising `SecurityError` and logging a
      # `CapabilityViolation` if missing.
      #
      # The capability must be globally granted (and not expired, and in
      # scope if a scope is set). Additionally, when per-window restrictions
      # are configured, *window_id* must be supplied and the capability must
      # appear in the window's effective set.
      #
      # Each failing check logs a separate `CapabilityViolation` and raises
      # `Core::SecurityError` (code `CAPABILITY_DENIED`).
      #
      # *context* is a free-form trace string recorded on the violation entry.
      def require!(capability : String, resource : String? = nil, context : String? = nil, window_id : String? = nil)
        unless check(capability, resource)
          violation = CapabilityViolation.new(capability, resource, context)
          audit_log(violation)
          raise Core::SecurityError.new(
            "Missing capability: #{capability}#{resource ? " for #{resource}" : ""}",
            code: "CAPABILITY_DENIED"
          )
        end

        return unless window_restrictions?

        unless window_id && effective_capabilities_for_window(window_id).includes?(capability)
          violation = CapabilityViolation.new(capability, resource, context || "window:#{window_id || "unknown"}")
          audit_log(violation)
          raise Core::SecurityError.new(
            "Missing capability: #{capability} for window '#{window_id || "unknown"}'",
            code: "CAPABILITY_DENIED"
          )
        end
      end

      # Returns the manifest's scope configuration for *feature* prefix, or
      # `nil` if none is configured. *feature* is the capability prefix
      # (e.g. `"fs"`, `"http"`). Do not mutate the returned array in place.
      def scope_config(feature : String) : Array(String)?
        @manifest.scopes[feature]?
      end

      # Runtime capability management (Requirement 25.10 / task 35.3)

      # Registers a handler called when a runtime capability request needs user
      # approval.
      #
      # The handler receives the capability name (a `String`) and must
      # return `true` (approved) or `false` (denied). Only one handler is
      # active at a time; registering a new one replaces the previous.
      #
      # ```
      # caps.set_prompt_handler do |capability|
      #   puts "Grant #{capability}? (y/n)"
      #   gets.chomp == "y"
      # end
      # ```
      def set_prompt_handler(&handler : String -> Bool)
        @prompt_handler = Proc(CapabilityRequest, CapabilityRequestOutcome).new do |req|
          handler.call(req.capability) ? CapabilityRequestOutcome::Approved : CapabilityRequestOutcome::Denied
        end
      end

      # Registers a handler that receives the full `CapabilityRequest` object,
      # exposing the request id, reason, and expiry to the prompt UI. The
      # handler must return `CapabilityRequestOutcome::Approved` or
      # `CapabilityRequestOutcome::Denied`. Only one handler is active at a
      # time; the most recently registered wins.
      def on_capability_request(&handler : CapabilityRequest -> CapabilityRequestOutcome)
        @prompt_handler = handler
      end

      # Requests *capability* at runtime, optionally prompting the user.
      #
      # If the capability is already granted this is a no-op and returns
      # `true`. If a prompt handler is registered it is called to ask the
      # user. If no handler is registered the request is denied (secure
      # default). When approved, the capability is granted; if *duration* is
      # provided it is granted as a temporary capability that expires after
      # that duration.
      #
      # *duration* takes precedence over *expires_at* when both are
      # supplied: the absolute expiry is `Time.utc + duration`. A denied
      # request is recorded as a `CapabilityViolation` with context
      # `"runtime_request_denied"` for audit.
      #
      # Returns `true` when the capability was (or already was) granted,
      # `false` when the user denied the request or no handler is registered.
      #
      # ```
      # ok = caps.request_capability("fs:write", reason: "Saving document", duration: 5.minutes)
      # ```
      def request_capability(
        capability : String,
        reason : String? = nil,
        duration : Time::Span? = nil,
        expires_at : Time? = nil,
      ) : Bool
        # Already granted and not expired — nothing to do
        return true if check(capability)

        # Resolve expiry: duration takes precedence over explicit expires_at
        effective_expires_at = if d = duration
                                 Time.utc + d
                               else
                                 expires_at
                               end

        req = CapabilityRequest.new(capability, reason, effective_expires_at)
        @pending_requests[req.id] = req

        outcome = if handler = @prompt_handler
                    handler.call(req)
                  else
                    # No handler registered: deny by default (secure default).
                    CapabilityRequestOutcome::Denied
                  end

        @pending_requests.delete(req.id)

        if outcome == CapabilityRequestOutcome::Approved
          grant(capability, expires_at: effective_expires_at)
          Log.info { "Runtime capability granted: '#{capability}'" \
                     "#{effective_expires_at ? " (expires #{effective_expires_at})" : ""}" \
                     "#{reason ? " — #{reason}" : ""}" }
          true
        else
          # Log a violation when the request is denied
          violation = CapabilityViolation.new(capability, nil, "runtime_request_denied")
          audit_log(violation)
          Log.info { "Runtime capability denied: '#{capability}'" }
          false
        end
      end

      # Grants *capability* temporarily; it expires after *duration*. To revoke
      # the grant early, call `#revoke`.
      def grant_temporary(capability : String, duration : Time::Span, scope : String? = nil)
        expires_at = Time.utc + duration
        grant(capability, scope, expires_at)
        Log.info { "Temporary capability granted: '#{capability}' for #{duration.total_seconds}s" }
      end

      # Grants *capability* to *window_id* temporarily; the grant expires after
      # *duration*. The window allow-list entry is not automatically removed
      # after expiry — call `#revoke_from_window` to do that explicitly.
      def grant_temporary_to_window(capability : String, window_id : String, duration : Time::Span)
        expires_at = Time.utc + duration
        grant_to_target(capability, window_id, @window_caps)
        @granted[capability] = CapabilityGrant.new(capability, nil, expires_at)
        Log.info { "Temporary window capability granted: '#{capability}' to window '#{window_id}' for #{duration.total_seconds}s" }
      end

      # Returns all currently pending (unanswered) runtime capability requests
      # as a fresh array. Pending requests can also be answered out-of-band
      # via `#approve_request` / `#deny_request`.
      def pending_requests : Array(CapabilityRequest)
        @pending_requests.values.dup
      end

      # Approves the pending request with id *request_id*, granting its
      # capability. Does not invoke the prompt handler — acts on a request
      # that is currently awaiting an answer (e.g. one displayed in a custom
      # UI). The request's `expires_at`, if any, is honored by the grant.
      #
      # Returns `true` if the request was found and approved, `false` if no
      # pending request with that id exists.
      def approve_request(request_id : String) : Bool
        req = @pending_requests.delete(request_id)
        return false unless req

        grant(req.capability, expires_at: req.expires_at)
        Log.info { "Pending capability request approved: '#{req.capability}' (id=#{req.id})" }
        true
      end

      # Denies the pending request with id *request_id* without granting its
      # capability. Unlike denials from `#request_capability` (which record a
      # `CapabilityViolation`), this path does not record a violation.
      #
      # Returns `true` if the request was found and denied, `false` if no
      # pending request with that id exists.
      def deny_request(request_id : String) : Bool
        req = @pending_requests.delete(request_id)
        return false unless req

        Log.info { "Pending capability request denied: '#{req.capability}' (id=#{req.id})" }
        true
      end
    end
  end
end
