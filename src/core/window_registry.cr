require "./window"
require "log"

module CrystKit
  module Core
    # The registry for application windows.
    #
    # Tracks every live `Core::Window` and provides id/label-based lookup
    # and primary-window semantics. Exposed through `App#window_registry`.
    #
    # * Labels are unique; registering a duplicate raises `ArgumentError`.
    # * The first registered window becomes the primary.
    #
    class WindowRegistry
      Log = ::Log.for(self)

      @windows = {} of String => Window
      @labels = {} of String => String
      @primary_id : String?
      @mutex = Mutex.new

      # Register a native window as a `Core::Window`.
      #
      # Raises `ArgumentError` if *label* is non-nil and already
      # registered. Returns the newly registered `Window`.
      def register(
        native : ::CrystKit::Core::EnhancedWindow,
        label : String? = nil,
        title : String = "Window",
        width : Int32 = 800,
        height : Int32 = 600,
        visible : Bool = true,
      ) : Window
        register_window(Window.new(native, label, title, width, height, visible))
      end

      # :nodoc:
      private def register_window(window : Window) : Window
        @mutex.synchronize do
          label = window.label
          if label && @labels.has_key?(label)
            raise ArgumentError.new("Window with label '#{label}' already exists")
          end

          @windows[window.id] = window
          @labels[label] = window.id if label
          @primary_id ||= window.id
          window
        end
      end

      # Returns the primary window (first registered), or `nil` if none.
      def primary : Window?
        @mutex.synchronize do
          id = @primary_id
          id ? @windows[id]? : nil
        end
      end

      # Look up a window by id or label, returning `nil` if not found.
      def find?(id_or_label : String) : Window?
        @mutex.synchronize { find_unlocked(id_or_label) }
      end

      # Look up a window by id or label, raising `ArgumentError` if not
      # found.
      def find(id_or_label : String) : Window
        find?(id_or_label) || raise ArgumentError.new("No matching window found")
      end

      # Returns every registered window.
      def all : Array(Window)
        @mutex.synchronize { @windows.values }
      end

      # Remove and return the window identified by id or label.
      #
      # Returns `nil` if not found. The native window is not destroyed;
      # call `Window#destroy` if needed.
      def remove(id_or_label : String) : Window?
        @mutex.synchronize do
          window = find_unlocked(id_or_label)
          return unless window

          @windows.delete(window.id)
          if label = window.label
            @labels.delete(label)
          end
          @primary_id = @windows.each_key.next.as?(String) if @primary_id == window.id
          window
        end
      end

      # Destroy every registered window and clear the registry.
      # Exceptions from individual destroys are logged and do not
      # prevent subsequent windows from being destroyed.
      def destroy_all : Nil
        # Snapshot to avoid concurrent mutation if a "destroy" lifecycle
        # handler calls back into the registry (e.g. `#remove`).
        windows = @mutex.synchronize do
          registered_windows = @windows.values
          @windows.clear
          @labels.clear
          @primary_id = nil
          registered_windows
        end
        windows.each do |window|
          begin
            window.destroy
          rescue ex
            Log.error(exception: ex) { {message: "WindowRegistry: destroy failed for window", id: window.id, label: window.label || "<unlabeled>"} }
          end
        end
      end

      private def find_unlocked(id_or_label : String) : Window?
        @windows[id_or_label]? || @labels[id_or_label]?.try { |id| @windows[id]? }
      end
    end
  end
end
