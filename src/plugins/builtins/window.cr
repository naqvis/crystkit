require "../base"
require "../../core/native_window"

module CrystKit
  module Core
    # Forward declaration for the window registry; the full type is defined in
    # the core subsystem. Declared here so the `Window` plugin can reference
    # it without pulling in the entire core require graph.
    class WindowRegistry; end
  end

  module Plugins
    # Builtin plugin that exposes window management (create, close, focus,
    # show/hide, geometry, state toggles, listing) to the frontend.
    #
    # Windows created here are the same windows the rest of the framework
    # tracks. Most commands take a window *label* to identify the target;
    # mutating commands require the `window:manage` capability, while the
    # read-only `window.list` and `window.exists` commands are public
    # (callable without a capability).
    #
    # Registers IPC commands:
    #   window:create — Create a new window with options
    #   window:close — Close a window by label
    #   window:focus — Focus a window by label
    #   window:show — Show a window by label
    #   window:hide — Hide a window by label
    #   window:set_size — Set window size
    #   window:set_title — Set window title
    #   window:set_position — Set window position
    #   window:minimize — Minimize a window
    #   window:maximize — Maximize a window
    #   window:restore — Restore a minimized/maximized window
    #   window:set_fullscreen — Toggle fullscreen on a window
    #   window:set_always_on_top — Toggle always-on-top on a window
    #   window:set_modal — Toggle modal on a window
    #   window:list — List all managed windows
    #   window:exists — Check if a window exists
    #
    # Required capability: `window:manage` (the 14 mutating commands);
    # `window.list` and `window.exists` are public.
    #
    # `window.create` accepts a JSON options object with `label` (required),
    # `title`, `width`, `height`, `url`/`html`, and flags `debug`, `modal`,
    # `always_on_top`, `frameless`, `transparent`, `opacity`, `x`/`y`,
    # `parent` (label), `minimize_to_tray`, and `fullscreen`. It returns
    # `{"label" => ...}`. Lookup commands raise `ArgumentError` when the label
    # is unknown.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Window.new)
    # ```
    class Window < Plugin::Base
      # The application's window registry, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! registry : Core::WindowRegistry

      # Returns the unique plugin identifier `"window"`.
      def identifier : String
        "window"
      end

      # Returns the metadata contract gating the 14 mutating commands behind
      # `window:manage` and marking `window.list` and `window.exists` as
      # public. The read-only commands use `IPC::PolicyCatalog#public` so
      # they bypass capability checks entirely — reserve this for genuinely
      # harmless reads.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(window.create window.close window.focus window.show window.hide window.set_size window.set_title window.set_position window.minimize window.maximize window.restore window.set_fullscreen window.set_always_on_top window.set_modal), "window:manage")
          .public(%w(window.list window.exists))

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(window:manage),
          commands: %w(window.create window.close window.focus window.show window.hide window.set_size window.set_title window.set_position window.minimize window.maximize window.restore window.set_fullscreen window.set_always_on_top window.set_modal window.list window.exists),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `window.create` accepts a JSON options object with `label` (required),
      # `title`, `width`, `height`, `url`/`html`, and flags `debug`, `modal`,
      # `always_on_top`, `frameless`, `transparent`, `opacity`, `x`/`y`,
      # `parent` (label), `minimize_to_tray`, and `fullscreen`. It returns
      # `{"label" => ...}`. Lookup commands raise `ArgumentError` when the
      # label is unknown. `window.list` returns `{label, title, visible}` for
      # each managed window.
      def initialize_plugin(context : Plugin::Context) : Nil
        @registry = registry = context.app.window_registry
        app = context.app

        context.command "window.create", JSON::Any do |opts|
          label = opts["label"].as_s
          title = opts["title"]?.try(&.as_s) || "Window"
          width = opts["width"]?.try(&.as_i) || 800
          height = opts["height"]?.try(&.as_i) || 600
          url = opts["url"]?.try(&.as_s)
          html = opts["html"]?.try(&.as_s)
          debug = opts["debug"]?.try(&.as_bool) || false
          modal = opts["modal"]?.try(&.as_bool) || false
          always_on_top = opts["always_on_top"]?.try(&.as_bool) || false
          frameless = opts["frameless"]?.try(&.as_bool) || false
          transparent = opts["transparent"]?.try(&.as_bool) || false
          opacity = opts["opacity"]?.try(&.as_f) || 1.0
          x = opts["x"]?.try(&.as_i)
          y = opts["y"]?.try(&.as_i)
          parent_label = opts["parent"]?.try(&.as_s)

          minimize_to_tray = opts["minimize_to_tray"]?.try(&.as_bool) || false
          fullscreen = opts["fullscreen"]?.try(&.as_bool) || false

          options = Core::WindowOptions.new(
            width: width, height: height, title: title, url: url,
            debug: debug, label: label, modal: modal,
            always_on_top: always_on_top, frameless: frameless,
            transparent: transparent, opacity: opacity,
            minimize_to_tray: minimize_to_tray, fullscreen: fullscreen,
            x: x, y: y,
          )

          window = app.window(options, html: html, parent_label: parent_label, x: x, y: y)

          {"label" => window.label || label}
        end

        context.command "window.close", String do |label|
          window = registry.remove(label)
          window.try(&.destroy)
        end

        context.command "window.focus", String do |label|
          window(registry, label).focus
        end

        context.command "window.show", String do |label|
          window(registry, label).show
        end

        context.command "window.hide", String do |label|
          window(registry, label).hide
        end

        context.command "window.set_size", String, Int32, Int32 do |label, width, height|
          window(registry, label).size(width, height, SizeHints::NONE)
        end

        context.command "window.set_title", String, String do |label, title|
          window(registry, label).title = title
        end

        context.command "window.set_position", String, Int32, Int32 do |label, pos_x, pos_y|
          window(registry, label).move(pos_x, pos_y)
        end

        context.command "window.minimize", String do |label|
          window(registry, label).minimize
        end

        context.command "window.maximize", String do |label|
          window(registry, label).maximize
        end

        context.command "window.restore", String do |label|
          window(registry, label).restore
        end

        context.command "window.set_fullscreen", String, Bool do |label, fullscreen|
          window(registry, label).fullscreen = fullscreen
        end

        context.command "window.set_always_on_top", String, Bool do |label, on_top|
          window(registry, label).always_on_top = on_top
        end

        context.command "window.set_modal", String, Bool do |label, modal|
          window(registry, label).modal = modal
        end

        context.command "window.list" do
          registry.all.compact_map do |window|
            if label = window.label
              {"label" => label, "title" => window.title, "visible" => window.visible?}
            end
          end
        end

        context.command "window.exists", String do |label|
          registry.find?(label) != nil
        end
      end

      # :nodoc: Looks up a window by label, raising `ArgumentError` when the
      # label is not registered. Shared by every label-keyed command.
      private def window(registry : Core::WindowRegistry, label : String) : Core::Window
        registry.find?(label) || raise ArgumentError.new("Window '#{label}' not found")
      end
    end
  end
end
