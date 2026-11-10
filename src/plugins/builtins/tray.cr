require "../base"
require "../../features/tray"

module CrystKit
  module Plugins
    # Builtin plugin that manages a system-tray (notification-area) icon with
    # an optional context menu.
    #
    # Manages a single tray icon, optionally attaches a context menu built
    # from a JSON description, and emits `tray.click` (when the icon is
    # clicked) and `tray.menu_click` (when a menu item is selected). Menus
    # support normal, checkbox, radio, and separator items with nested
    # submenus up to `Features::TrayMenu::MAX_DEPTH`.
    #
    # Registers IPC commands:
    #   tray:create — Create a system tray icon
    #   tray:update_icon — Update the tray icon
    #   tray:set_tooltip — Set the tray tooltip text
    #   tray:set_menu — Set the tray context menu
    #   tray:destroy — Destroy the system tray icon
    #
    # Emits events: `tray.click`, `tray.menu_click`
    #
    # Required capability: `tray:manage`
    #
    # `tray.create` accepts a JSON object with `icon` (VFS path, URL, or theme name), optional
    # `tooltip`, and optional `menu` (array of item descriptors). Item
    # descriptors carry `type` (`normal`, `checkbox`, `radio`, `separator`),
    # `id`, `label`, `enabled`, `checked`, and nested `items`.
    #
    # ```
    # app.plugin(CrystKit::Plugins::Tray.new)
    # ```
    class Tray < Plugin::Base
      # The system-tray feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! tray : Features::SystemTray

      # Returns the unique plugin identifier `"tray"`.
      def identifier : String
        "tray"
      end

      # Returns the metadata contract gating every tray command behind the
      # `tray:manage` capability and declaring the `tray.click` and
      # `tray.menu_click` events.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(tray.create tray.update_icon tray.set_tooltip tray.set_menu tray.destroy tray.created), "tray:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(tray:manage),
          commands: %w(tray.create tray.update_icon tray.set_tooltip tray.set_menu tray.destroy tray.created),
          events: %w(tray.click tray.menu_click),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `tray.create` accepts a JSON object with `icon` (VFS path, URL, or theme name), optional
      # `tooltip`, and optional `menu` (array of item descriptors). Item
      # descriptors carry `type` (`normal`, `checkbox`, `radio`, `separator`),
      # `id`, `label`, `enabled`, `checked`, and nested `items`. Item clicks
      # emit `tray.menu_click` with the item id.
      def initialize_plugin(context : Plugin::Context) : Nil
        @tray = tray = Features::SystemTray.new(
          context.capabilities,
          app_id: context.app.config.identifier,
          asset_source: context.app.asset_source,
          asset_fetcher: context.app.asset_fetcher,
        )

        context.command "tray.create", JSON::Any do |opts|
          icon_str = opts["icon"]?.try(&.as_s?) || raise Core::Error.new("Missing 'icon' field", code: "BAD_REQUEST")
          icon = parse_icon_arg(icon_str)
          tooltip = opts["tooltip"]?.try(&.as_s)
          tray.create(icon, tooltip)

          tray.on_click do |button|
            context.emit("tray.click", context.app.coerce_to_json({"button" => button.to_s.downcase}))
          end

          if menu_arr = opts["menu"]?.try(&.as_a)
            menu = build_menu_from_json(menu_arr, context)
            tray.menu = menu
          end
        end

        context.command "tray.update_icon", String do |icon_str|
          tray.update_icon(parse_icon_arg(icon_str))
        end

        context.command "tray.set_tooltip", String do |text|
          tray.tooltip = text
        end

        context.command "tray.set_menu", JSON::Any do |menu_json|
          if arr = menu_json.as_a?
            menu = build_menu_from_json(arr, context)
            tray.menu = menu
          end
        end

        context.command "tray.destroy" do
          tray.destroy
        end

        context.command "tray.created" do
          {"created" => tray.created?}
        end
      end

      # Destroys the tray icon if one was created.
      def cleanup_plugin : Nil
        @tray.try(&.destroy)
      end

      # Parse an icon string from IPC into the right type for tray.create.
      #   "http://..." / "https://..." -> URI (async network fetch)
      #   everything else -> String (AssetResolution checks VFS, falls
      #                       back to theme name if VFS doesn't have it)
      private def parse_icon_arg(icon_str : String)
        if icon_str.starts_with?("http://") || icon_str.starts_with?("https://")
          URI.parse(icon_str)
        else
          icon_str
        end
      end

      # :nodoc: Recursively builds a `Features::TrayMenu` from a JSON array of
      # item descriptors.
      #
      # Each item's `type` selects `Normal`, `Checkbox`, `Radio`, or
      # `Separator`. Non-separator items get an `id` (defaulting to a random
      # hex string), `label`, `enabled`, and `checked` state. Nested `items`
      # build a submenu up to `Features::TrayMenu::MAX_DEPTH`; deeper nesting
      # is silently dropped. Every clickable item installs an `on_click`
      # callback that emits `tray.menu_click` with its `item_id`.
      private def build_menu_from_json(items : Array(JSON::Any), context : Plugin::Context, depth : Int32 = 1) : Features::TrayMenu
        menu = Features::TrayMenu.new
        items.each do |item|
          type_str = item["type"]?.try(&.as_s) || "normal"
          type = case type_str
                 when "checkbox"  then Features::TrayMenuItemType::Checkbox
                 when "radio"     then Features::TrayMenuItemType::Radio
                 when "separator" then Features::TrayMenuItemType::Separator
                 else                  Features::TrayMenuItemType::Normal
                 end

          if type.separator?
            menu.add_separator
          else
            mi = Features::TrayMenuItem.new(
              item["id"]?.try(&.as_s) || Random::Secure.hex(8),
              item["label"]?.try(&.as_s) || "",
              type,
            )
            mi.enabled = item["enabled"]?.try(&.as_bool) || true
            mi.checked = item["checked"]?.try(&.as_bool) || false

            if sub = item["items"]?.try(&.as_a)
              if depth < Features::TrayMenu::MAX_DEPTH
                mi.submenu = build_menu_from_json(sub, context, depth + 1)
              end
            end

            mi.on_click do |evt|
              context.emit("tray.menu_click", context.app.coerce_to_json({"item_id" => evt.item_id}))
            end

            menu.add_item(mi, depth)
          end
        end
        menu
      end
    end
  end
end
