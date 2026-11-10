require "../base"
require "../../features/menu"

module CrystKit
  module Plugins
    # Application menu bar plugin building, installing, and updating native
    # menu bars from JSON descriptions.
    #
    # Translates a JSON menu description (menus, items, separators, submenus)
    # into native menu objects and installs them on the primary window. Item
    # clicks are bridged back to the frontend as `menu.click` events carrying
    # the item id.
    #
    # Registers IPC commands:
    #   menu:build — Build and install a custom menu bar from JSON
    #   menu:standard — Install the standard application menu bar
    #   menu:set_enabled — Enable or disable a menu item by ID
    #   menu:set_checked — Check or uncheck a menu item by ID
    # Emits events: menu.click
    #
    # All commands require the `menu:manage` capability.
    class MenuBar < Plugin::Base
      getter! menu_bar : Features::MenuBar

      def identifier : String
        "menu_bar"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(menu.build menu.standard menu.set_enabled menu.set_checked), "menu:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(menu:manage),
          commands: %w(menu.build menu.standard menu.set_enabled menu.set_checked),
          events: %w(menu.click),
          ipc: ipc,
        )
      end

      # `menu.build` clears the current menus and rebuilds them from a JSON
      # array of menu descriptions; each leaf item emits `menu.click` with its
      # id when activated. `menu.standard` installs the conventional
      # platform-standard menu bar using *app_name* as the application label.
      # `menu.set_enabled` and `menu.set_checked` mutate a menu item by id and
      # reinstall the menu bar so changes take effect immediately.
      def initialize_plugin(context : Plugin::Context) : Nil
        @context = context
        @menu_bar = mb = Features::MenuBar.new

        context.command "menu.build", JSON::Any do |menus_json|
          mb.menus.clear
          menus_json.as_a.each do |menu_entry|
            menu = build_menu(menu_entry, context)
            mb.add(menu)
          end
          install(mb)
        end

        context.command "menu.standard", String do |app_name|
          mb.menus.clear
          standard = Features::MenuBar.standard(app_name)
          standard.menus.each { |menu| mb.add(menu) }
          install(mb)
        end

        context.command "menu.set_enabled", String, Bool do |item_id, enabled|
          update_item(mb, item_id, &.enabled=(enabled))
          install(mb)
        end

        context.command "menu.set_checked", String, Bool do |item_id, checked|
          update_item(mb, item_id, &.checked=(checked))
          install(mb)
        end
      end

      # Install the menu bar on the primary window's native handle. macOS
      # installs globally and ignores the pointer.
      # :nodoc:
      private def install(mb : Features::MenuBar) : Nil
        ptr = @context.try(&.app.primary_window).try(&.window)
        mb.install(ptr)
      end

      # :nodoc:
      @context : Plugin::Context?

      # :nodoc: Recursively builds a `Features::Menu` from a JSON menu entry.
      #
      # Leaf items without an explicit id receive a secure random id. Items
      # with a `type` of `separator` add a separator; items with nested
      # `items` are added as submenus; everything else becomes a
      # `Features::MenuItem` whose action emits `menu.click` with the item id.
      private def build_menu(entry : JSON::Any, context : Plugin::Context) : Features::Menu
        label = entry["label"].as_s
        id = entry["id"]?.try(&.as_s) || label.downcase.gsub(/\s+/, "-")
        menu = Features::Menu.new(label, id)

        (entry["items"]?.try(&.as_a) || [] of JSON::Any).each do |item|
          if item["type"]?.try(&.as_s) == "separator"
            menu.add_separator
          elsif _sub_items = item["items"]?.try(&.as_a)
            sub_menu = build_menu(item, context)
            menu.add_submenu(sub_menu)
          else
            mi_id = item["id"]?.try(&.as_s) || Random::Secure.hex(8)
            mi_label = item["label"]?.try(&.as_s) || ""
            mi_accel = item["accelerator"]?.try(&.as_s)
            mi_enabled = item["enabled"]?.try(&.as_bool) || true
            mi_checked = item["checked"]?.try(&.as_bool) || false

            mi = Features::MenuItem.new(
              id: mi_id,
              label: mi_label,
              enabled: mi_enabled,
              checked: mi_checked,
              accelerator: mi_accel,
              action: -> { context.emit("menu.click", context.app.coerce_to_json({"item_id" => mi_id})) },
            )
            menu.items << mi
          end
        end

        menu
      end

      # :nodoc: Applies the given mutation block to the menu item identified by
      # *item_id* across all menus, stopping at the first match.
      private def update_item(menu_bar : Features::MenuBar, item_id : String, &block : Features::MenuItem ->) : Nil
        menu_bar.menus.each do |menu|
          found = find_in_menu(menu, item_id)
          if found
            block.call(found)
            return
          end
        end
      end

      # :nodoc: Depth-first search for a menu item by id, descending into
      # submenus.
      private def find_in_menu(menu : Features::Menu, item_id : String) : Features::MenuItem?
        menu.items.each do |item|
          case item
          when Features::MenuItem
            return item if item.id == item_id
          when Features::Menu
            found = find_in_menu(item, item_id)
            return found if found
          end
        end
        nil
      end
    end
  end
end
