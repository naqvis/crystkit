require "json"

module CrystKit::Security
  # A pending runtime request for a capability.
  #
  # Created by `CapabilitySystem#request_capability` whenever code asks
  # for a capability that is not currently granted. The request is handed
  # to the registered prompt handler and tracked until answered — either
  # synchronously by the handler's return value, or out-of-band via
  # `CapabilitySystem#approve_request` / `CapabilitySystem#deny_request`.
  #
  # Each instance is given a cryptographically random *id* so a UI can
  # refer to it unambiguously across IPC boundaries. The struct is
  # `JSON::Serializable` so it can be shipped to a frontend prompt UI.
  struct CapabilityRequest
    include JSON::Serializable

    # Cryptographically random identifier for this request.
    #
    # 16 hex characters (8 bytes of entropy), sufficient for in-process
    # uniqueness. Relying parties that need cross-process uniqueness
    # should additionally validate the request's *capability* field
    # before approving.
    getter id : String

    # The capability identifier being requested (e.g. `"fs:write"`).
    getter capability : String

    # Optional human-readable reason for the request, intended for
    # display in the prompt UI. `nil` when the caller did not supply a
    # reason.
    getter reason : String?

    # UTC timestamp at which the request was created.
    getter requested_at : Time

    # Optional UTC timestamp after which the resulting grant, if
    # approved, will expire. This is *not* a deadline for answering the
    # request itself — the pending entry remains until approved or
    # denied.
    getter expires_at : Time?

    # Creates a new request for *capability* with optional *reason* and
    # *expires_at*. `id` and `requested_at` are populated automatically.
    def initialize(
      @capability : String,
      @reason = nil,
      @expires_at = nil,
    )
      @id = Random::Secure.hex(8)
      @requested_at = Time.utc
    end
  end

  # The outcome of a `CapabilityRequest`, returned by prompt handlers.
  #
  # `Approved` instructs the capability system to grant the requested
  # capability; `Denied` instructs it to deny access and record a
  # violation.
  enum CapabilityRequestOutcome
    # The request was approved: the capability should be granted.
    Approved
    # The request was denied: the capability should not be granted.
    Denied
  end
end
