require "json"
require "../../core/window"

module CrystKit
  module Platform
    # Abstract interface for receiving native drag-and-drop events on a window.
    abstract class DragDropBackend
      # Installs drop handling on *window*, invoking *on_over* while content
      # is dragged over the window and *on_drop* when it is released.
      #
      # Both callbacks receive the dragged `files` (an `Array(String)` of
      # paths, possibly empty) and the optional `text` payload.
      abstract def attach(
        window : Core::Window,
        on_over : Proc(Array(String), String?, Nil),
        on_drop : Proc(Array(String), String?, Nil),
      ) : Nil

      # Removes drop handling from the window identified by *window_id*.
      abstract def detach(window_id : String) : Nil
    end

    # :nodoc: No-op `DragDropBackend` used when drag-and-drop is unavailable.
    class NullDragDropBackend < DragDropBackend
      # :nodoc:
      def attach(window, on_over, on_drop) : Nil
      end

      # :nodoc:
      def detach(window_id : String) : Nil
      end
    end

    # :nodoc:
    class CurrentDragDropBackend < DragDropBackend
      # :nodoc:
      private struct Payload
        include JSON::Serializable

        getter kind : String
        getter files : Array(String)
        getter text : String?

        def initialize(@kind : String, @files : Array(String), @text : String?)
        end
      end

      @attached = Set(String).new

      # :nodoc:
      def attach(
        window : Core::Window,
        on_over : Proc(Array(String), String?, Nil),
        on_drop : Proc(Array(String), String?, Nil),
      ) : Nil
        return if @attached.includes?(window.id)

        binding = "__crystkit_drag_drop_#{window.id.gsub('-', '_')}"
        window.bind_typed(binding, Payload) do |payload|
          case payload.kind
          when "over"
            on_over.call(payload.files, payload.text)
          when "drop"
            on_drop.call(payload.files, payload.text)
          end
          nil
        end
        window.init(bridge_script(binding))
        @attached << window.id
      end

      # :nodoc:
      def detach(window_id : String) : Nil
        @attached.delete(window_id)
      end

      # :nodoc:
      private def bridge_script(binding : String) : String
        <<-JS
        (() => {
          const emit = (kind, transfer) => {
            const files = Array.from(transfer.files || []).map(file =>
              file.path || file.webkitRelativePath || file.name
            );
            const text = transfer.getData ? (transfer.getData("text/plain") || null) : null;
            window[#{binding.to_json}]({kind, files, text});
          };
          window.addEventListener("dragover", event => {
            event.preventDefault();
            emit("over", event.dataTransfer);
          });
          window.addEventListener("drop", event => {
            event.preventDefault();
            emit("drop", event.dataTransfer);
          });
        })();
        JS
      end
    end
  end
end
