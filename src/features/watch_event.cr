module CrystKit::Features
  # A single filesystem event emitted by a directory or file watcher.
  #
  # Carries the event *type* as a free-form string, the absolute
  # *path* of the resource that changed, and optionally the previous
  # path for rename events.
  #
  # The *type* string is one of `"created"`, `"modified"`,
  # `"deleted"`, `"renamed"`, or `"metadata"`. Consumers should treat
  # unknown types as a signal to rescan the watched path.
  #
  # Error events from the underlying backend are logged internally and
  # never delivered as `WatchEvent` values.
  struct WatchEvent
    # Platform-defined event kind (e.g. `"modified"`, `"deleted"`).
    getter type : String

    # Absolute path of the filesystem entry the event applies to.
    getter path : String

    # Previous path for rename events, `nil` otherwise.
    getter old_path : String?

    # Creates a new event.
    def initialize(@type : String, @path : String, @old_path : String? = nil)
    end
  end
end
