require "../base"
require "../../features/drag_drop"
require "../../platform/backends/drag_drop_backend"

module CrystKit
  module Plugins
    # Plugin bridging platform drag & drop events onto CrystKit's IPC event
    # bus.
    #
    # A pure-event plugin: declares no IPC commands, only the `drag.drop` and
    # `drag.over` events. The emitted payload is a JSON object with `files`
    # (array of paths), `text` (string or `null`), and `window` (the window
    # label when set, otherwise the numeric window id).
    #
    # Emits events:
    #   drag.drop — fired when files or text are released onto a window
    #   drag.over — fired while a payload is hovering over a window
    #
    # No capabilities are required.
    #
    # ```
    # app.plugin(CrystKit::Plugins::DragDrop.new)
    # ```
    class DragDrop < Plugin::Base
      getter! drag : Features::DragDrop

      # :nodoc:
      @context : Plugin::Context?

      # :nodoc:
      @backend : Platform::DragDropBackend?

      def identifier : String
        "drag_drop"
      end

      def metadata : Plugin::Metadata
        Plugin::Metadata.new(
          identifier,
          events: %w(drag.drop drag.over),
        )
      end

      def initialize_plugin(context : Plugin::Context) : Nil
        @context = context
        @backend = context.app.runtime.platform.drag_drop
        @drag = Features::DragDrop.new
      end

      # Attaches the platform drag-drop backend to each newly created window.
      # No-op when the platform exposes no drag-drop backend.
      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        backend = @backend
        return unless backend

        backend.attach(
          window,
          ->(files : Array(String), text : String?) { emit("drag.over", window, files, text) },
          ->(files : Array(String), text : String?) { emit("drag.drop", window, files, text) },
        )
        window.on("destroy") { backend.detach(window.id) }
      end

      # :nodoc:
      private def emit(event_name : String, window : ::CrystKit::Core::Window, files : Array(String), text : String?) : Nil
        event = Features::DragDropEvent.new(files, text)
        event_name == "drag.drop" ? drag.handle_drop(event) : drag.handle_drag_over(event)

        @context.try do |context|
          context.emit(event_name, context.app.coerce_to_json({
            "files"  => files,
            "text"   => text,
            "window" => window.label || window.id,
          }))
        end
      end
    end
  end
end
