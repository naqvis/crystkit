require "json"
require "../../features/toolbar"
require "../../core/window"

module CrystKit
  module Plugins
    # Builtin plugin that manages a native toolbar (item bar) attached to the
    # application window.
    #
    # An in-memory model of toolbar items (id, label, icon, enabled state,
    # style) is mirrored onto the native toolbar attached to the first window
    # created after the plugin is registered. Child windows do not inherit it.
    #
    # Registers IPC commands:
    #   toolbar:add_item, toolbar:remove_item, toolbar:clear,
    #   toolbar:show, toolbar:hide, toolbar:visible?,
    #   toolbar:set_style, toolbar:set_title, toolbar:items
    # Emits events: toolbar.click
    #
    # Required capability: `toolbar:manage`
    #
    # `toolbar.set_style` parses its string argument into a
    # `Features::ToolbarStyle` and returns `{"success" => false, "error" => ...}`
    # for an unknown style name rather than raising.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Toolbar.new)
    # ```
    class Toolbar < Plugin::Base
      @owner_window_id : String?

      # :nodoc:
      def initialize(@provider : Features::Toolbar::Provider = Features::Toolbar::NativeProvider.new)
      end

      # The toolbar model, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! toolbar : Features::Toolbar

      # Returns the unique plugin identifier `"toolbar"`.
      def identifier : String
        "toolbar"
      end

      # Returns the metadata contract gating every toolbar command behind the
      # `toolbar:manage` capability.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(toolbar.add_item toolbar.add_toggle toolbar.add_dropdown toolbar.add_color toolbar.remove_item toolbar.clear toolbar.add_separator toolbar.show toolbar.hide toolbar.visible? toolbar.set_style toolbar.set_title toolbar.icon_dir toolbar.items), "toolbar:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(toolbar:manage),
          commands: %w(toolbar.add_item toolbar.add_toggle toolbar.add_dropdown toolbar.add_color toolbar.remove_item toolbar.clear toolbar.add_separator toolbar.show toolbar.hide toolbar.visible? toolbar.set_style toolbar.set_title toolbar.icon_dir toolbar.items),
          events: %w(toolbar.click toolbar.dropdown_selected),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `items` returns the current model as `{"items" => [...]}` with each
      # item's `id`, `label`, `icon`, and `enabled` flag.
      def initialize_plugin(context : Plugin::Context) : Nil
        @toolbar = Features::Toolbar.new(
          context.capabilities,
          provider: @provider,
        )
        context.command "toolbar.add_separator" do
          toolbar.add_separator
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.add_item", String, String, String? do |id, label, icon|
          toolbar.add_item(id, label, icon) do
            context.emit("toolbar.click", context.app.coerce_to_json({"item_id" => id}))
          end
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.add_toggle", String, String, String?, Bool do |id, label, icon, checked|
          toolbar.add_toggle(id, label, icon, checked) do
            context.emit("toolbar.click", context.app.coerce_to_json({"item_id" => id}))
          end
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.add_color", String, String, String do |id, label, color|
          toolbar.add_color(id, label, color) do
            context.emit("toolbar.click", context.app.coerce_to_json({"item_id" => id}))
          end
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.add_dropdown", String, String, String?, Array(String), Int32 do |id, label, icon, options, selected_index|
          toolbar.add_dropdown(id, label, icon, options, selected_index) do
            context.emit("toolbar.dropdown_selected", context.app.coerce_to_json({"item_id" => id}))
          end
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.remove_item", String do |id|
          toolbar.remove_item(id)
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.clear" do
          toolbar.clear
          toolbar.sync
          {"success" => true}
        end

        context.command "toolbar.show" do
          toolbar.show
          toolbar.native_visible = true
          {"success" => true}
        end

        context.command "toolbar.hide" do
          toolbar.hide
          toolbar.native_visible = false
          {"success" => true}
        end

        context.command "toolbar.visible?" do
          {"visible" => toolbar.visible?}
        end

        context.command "toolbar.set_style", String do |style_s|
          style = Features::ToolbarStyle.parse?(style_s)
          next {"success" => false, "error" => "Unknown style: #{style_s}"} unless style
          toolbar.style = style
          {"success" => true}
        end

        context.command "toolbar.set_title", String do |title|
          toolbar.title = title
          {"success" => true}
        end

        context.command "toolbar.icon_dir", String do |dir|
          toolbar.icon_dir = dir
          {"icon_dir" => toolbar.icon_dir}
        end

        context.command "toolbar.items" do
          {"items" => toolbar.items.map { |item|
            obj = {
              "id"      => JSON::Any.new(item.id),
              "label"   => JSON::Any.new(item.label),
              "icon"    => item.icon_arg ? JSON::Any.new(item.icon_arg) : JSON::Any.new(nil),
              "enabled" => JSON::Any.new(item.enabled?),
              "type"    => JSON::Any.new(item.item_type.to_s.downcase),
              "checked" => JSON::Any.new(item.checked?),
            }
            if item.item_type == Features::ToolbarItemType::Dropdown
              obj["options"] = JSON::Any.new(item.options.map { |o| JSON::Any.new(o) })
              obj["selected_index"] = JSON::Any.new(item.selected_index.to_i64)
            end
            if item.item_type == Features::ToolbarItemType::Color
              obj["color"] = JSON::Any.new(item.color)
            end
            JSON::Any.new(obj)
          }}
        end
      end

      def cleanup_plugin : Nil
        @toolbar.try(&.cleanup)
      end

      def on_window_created(window : ::CrystKit::Core::Window) : Nil
        return if @owner_window_id
        @owner_window_id = window.id
        window.toolbar = toolbar
      end
    end
  end
end
