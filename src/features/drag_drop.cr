require "log"

module CrystKit::Features
  # Drag & drop event data.
  #
  # Describes a payload that has entered or been released onto the webview
  # window. The payload may carry file paths, text content, or both — check
  # `#has_files?` and `#text` to determine what was dropped.
  #
  # Handlers may set `#prevent_default = true` to suppress the platform's
  # default drop behaviour.
  struct DragDropEvent
    # Dropped file paths.
    #
    # Empty when the drop carried no files. The paths are platform-native
    # strings and are not guaranteed to exist.
    getter files : Array(String)

    # Dropped text content, or `nil` when the drop carried no text payload.
    getter text : String?

    # Whether the default action should be prevented.
    #
    # Handlers set this to `true` to suppress the platform's default drop
    # behaviour. Defaults to `false`.
    property? prevent_default : Bool

    # Creates a drop event carrying *files* and optional *text*.
    #
    # Both arguments are optional so the event can describe a files-only,
    # text-only, or mixed payload. `prevent_default` defaults to `false`.
    def initialize(@files : Array(String) = [] of String, @text = nil)
      @prevent_default = false
    end

    # Returns `true` when the event carries at least one file path.
    def has_files? : Bool
      !@files.empty?
    end
  end

  # Handles drag & drop of files and text onto the webview window.
  #
  # Registration point for application-level drop handlers. It maintains two
  # independent handler lists — drop handlers (fired on release) and
  # drag-over handlers (fired while the payload is hovering over the window)
  # — and forwards events to the frontend via `#emit_to_frontend`.
  #
  # Usage:
  # ```
  # wv.on_drag_drop do |event|
  #   event.files.each { |f| puts "Dropped: #{f}" }
  # end
  # ```
  class DragDrop
    Log = ::Log.for(self)

    @handlers : Array(Proc(DragDropEvent, Nil))
    @over_handlers : Array(Proc(DragDropEvent, Nil))

    # Creates an empty drag & drop dispatcher with no registered handlers.
    def initialize
      @handlers = [] of Proc(DragDropEvent, Nil)
      @over_handlers = [] of Proc(DragDropEvent, Nil)
    end

    # Register a handler for when files/text are dropped.
    #
    # The block is invoked synchronously in registration order for each drop
    # event. Multiple handlers may be registered; each receives the same
    # `DragDropEvent` instance, so mutating `#prevent_default` in one handler
    # is visible to the next. Returns `self` so registrations can be chained.
    def on_drop(&block : DragDropEvent -> Nil) : self
      @handlers << block
      self
    end

    # Register a handler for when something is dragged over the window.
    #
    # Drag-over handlers fire on every drag-enter and drag-move event, before
    # the payload is released. Multiple may be registered and they fire in
    # registration order. Returns `self` for chaining.
    def on_drag_over(&block : DragDropEvent -> Nil) : self
      @over_handlers << block
      self
    end

    # Called by the platform layer when a drop occurs.
    #
    # Invokes every registered drop handler in registration order with
    # *event*. Application code registers handlers via `#on_drop` and does
    # not call this method directly.
    def handle_drop(event : DragDropEvent) : Nil
      @handlers.each(&.call(event))
    end

    # Called by the platform layer when a drag enters/moves.
    #
    # Invokes every registered drag-over handler in registration order with
    # *event*. Application code does not call this method directly.
    def handle_drag_over(event : DragDropEvent) : Nil
      @over_handlers.each(&.call(event))
    end

    # Emit drop event to the frontend via IPC.
    #
    # Forwards *event* to *app* via `App#emit` under the `"drag:drop"` event
    # name, with a payload of shape `{"files": [...], "text": ...}`. The
    # `text` field is `null` when the event carried no text.
    def emit_to_frontend(app : App, event : DragDropEvent) : Nil
      payload = JSON::Any.new({
        "files" => JSON::Any.new(event.files.map { |file_path| JSON::Any.new(file_path) }),
        "text"  => JSON::Any.new(event.text ? JSON::Any.new(event.text) : JSON::Any.new(nil)),
      })
      app.emit("drag:drop", payload)
    end
  end
end
