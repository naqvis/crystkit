require "../base"
require "../../features/window_effects"

module CrystKit
  module Plugins
    # Builtin plugin that applies native window background effects
    # (vibrancy, mica, acrylic, blur-behind) to the application's primary
    # window.
    #
    # Effects are platform-specific: vibrancy is macOS, mica and acrylic are
    # Windows 11, blur-behind is Windows 10/Linux compositors. The backend is
    # a no-op where unsupported, so commands are safe to call everywhere.
    #
    # Registers IPC commands:
    #   we:vibrancy — Apply vibrancy material effect to the window
    #   we:mica — Apply mica effect to the window
    #   we:acrylic — Apply acrylic effect to the window
    #   we:blur — Apply blur-behind effect to the window
    #   we:clear — Clear all window effects
    #
    # Required capability: `window:effects`
    #
    # `we.vibrancy` accepts an optional material name (`dark`, `light`,
    # `ultra_dark`, `sidebar`, `window`, `hud_window`, `menu`, `popover`,
    # `selection`), defaulting to `dark`.
    #
    # ```
    # app.plugin(CrystKit::Plugins::WEffects.new)
    # ```
    class WEffects < Plugin::Base
      # :nodoc:
      def initialize(@provider : Features::WindowEffectsProvider = Features::NativeWindowEffectsProvider.new)
      end

      # The window-effects feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! effects : Features::WindowEffects

      # Returns the unique plugin identifier `"window_effects"`.
      def identifier : String
        "window_effects"
      end

      # Returns the metadata contract gating every effect command behind the
      # `window:effects` capability.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(we.vibrancy we.mica we.acrylic we.blur we.clear), "window:effects")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(window:effects),
          commands: %w(we.vibrancy we.mica we.acrylic we.blur we.clear),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `we.clear` resets all four flags to false. The vibrancy command parses
      # its material argument case-insensitively, defaulting to `dark`.
      def initialize_plugin(context : Plugin::Context) : Nil
        @effects = eff = Features::WindowEffects.new(
          capabilities: context.capabilities,
          provider: @provider,
        )

        context.command "we.vibrancy", String? do |material_str|
          material = case (material_str || "dark").downcase
                     when "light"      then :light
                     when "ultra_dark" then :ultra_dark
                     when "sidebar"    then :sidebar
                     when "window"     then :window
                     when "hud_window" then :hud_window
                     when "menu"       then :menu
                     when "popover"    then :popover
                     when "selection"  then :selection
                     else                   :dark
                     end
          eff.config.vibrancy = true
          eff.config.material = material
          apply_window(eff, context)
        end

        context.command "we.mica" do
          eff.config.mica = true
          apply_window(eff, context)
        end

        context.command "we.acrylic" do
          eff.config.acrylic = true
          apply_window(eff, context)
        end

        context.command "we.blur" do
          eff.config.blur_behind = true
          apply_window(eff, context)
        end

        context.command "we.clear" do
          eff.config.vibrancy = false
          eff.config.mica = false
          eff.config.acrylic = false
          eff.config.blur_behind = false
          apply_window(eff, context)
        end
      end

      # :nodoc: Applies the current effect config to the primary window.
      #
      # Resolves `app.primary_window` and, when present and its native handle
      # is non-null, calls `eff.apply(ptr)` to render the configured effects.
      # No-ops when there is no primary window yet or the handle is null.
      private def apply_window(eff : Features::WindowEffects, context : Plugin::Context) : Nil
        wv = context.app.primary_window
        if wv
          ptr = wv.window
          eff.apply(ptr) unless ptr.null?
        end
      end
    end
  end
end
