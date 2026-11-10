require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../security/capability"
require "../platform/interface"
require "./asset_resolution"
require "./asset_source"
require "./asset_fetcher"
require "../platform/icon_source"

module CrystKit
  module Features
    # Mouse button identifier reported by tray click events.
    enum MouseButton
      Left
      Right
      Middle
    end

    # Behavioral type of a `TrayMenuItem`.
    #
    # * `Normal` — a plain clickable entry.
    # * `Checkbox` — a toggle entry with a checkmark state (`TrayMenuItem#checked`).
    # * `Radio` — a mutually-exclusive entry within a group.
    # * `Separator` — a non-interactive horizontal rule used to group entries.
    enum TrayMenuItemType
      Normal
      Checkbox
      Radio
      Separator
    end

    # Event payload delivered to `TrayMenuItem#on_click` handlers.
    #
    # The *timestamp* reflects when the click was reported, not when the
    # handler runs, so it can be used to order or debounce rapid clicks.
    struct TrayMenuItemEvent
      getter item_id : String
      getter timestamp : Time

      # Creates an event for the menu item identified by *item_id*,
      # stamped with the current UTC time.
      def initialize(@item_id : String)
        @timestamp = Time.utc
      end
    end

    # A single entry in a tray context menu, with an optional nested submenu.
    #
    # Each item has a stable *id* (used as the callback key), a display
    # *label*, a `TrayMenuItemType`, and mutable *enabled* / *checked*
    # flags. The *id* must be unique within its menu.
    class TrayMenuItem
      getter id : String
      getter label : String
      property? enabled : Bool
      property? checked : Bool
      property type : TrayMenuItemType
      property accelerator : String?
      getter submenu : TrayMenu?
      @click_handler : Proc(TrayMenuItemEvent, Nil)?

      # Creates a menu item. New items start enabled and unchecked.
      def initialize(@id : String, @label : String, @type = TrayMenuItemType::Normal, @accelerator : String? = nil)
        @enabled = true
        @checked = false
      end

      # Registers *block* as the click handler for this item.
      #
      # Only one handler is kept per item; registering a new one
      # replaces the previous.
      def on_click(&block : TrayMenuItemEvent ->)
        @click_handler = block
      end

      # :nodoc:
      def trigger_click
        @click_handler.try(&.call(TrayMenuItemEvent.new(@id)))
      end

      # Attaches *menu* as a submenu of this item.
      #
      # Nesting depth is bounded by `TrayMenu::MAX_DEPTH`; deeper nesting
      # raises when the menu is flattened.
      def submenu=(menu : TrayMenu)
        @submenu = menu
      end
    end

    # A tray context menu composed of `TrayMenuItem` entries.
    #
    # Supports nested submenus up to `MAX_DEPTH` levels deep; attempting
    # to exceed that depth raises `Core::Error`.
    class TrayMenu
      # Maximum nesting depth for submenus (top-level items are depth 1).
      MAX_DEPTH = 3

      @items : Array(TrayMenuItem)

      # Creates an empty menu.
      def initialize
        @items = [] of TrayMenuItem
      end

      # Returns a copy of the menu's items.
      def items : Array(TrayMenuItem)
        @items.dup
      end

      # Appends *item* to the menu, enforcing the nesting depth limit.
      #
      # Raises `Core::Error` with code `MENU_DEPTH_EXCEEDED`
      # when *current_depth* exceeds `MAX_DEPTH`.
      def add_item(item : TrayMenuItem, current_depth : Int32 = 1)
        if current_depth > MAX_DEPTH
          raise Core::Error.new(
            "Menu nesting depth exceeds maximum of #{MAX_DEPTH} levels",
            code: "MENU_DEPTH_EXCEEDED"
          )
        end
        @items << item
      end

      # Convenience overload that creates an item, attaches the click
      # handler, and adds it to the menu in one call.
      def add_item(id : String, label : String, type = TrayMenuItemType::Normal, accelerator : String? = nil, &block : TrayMenuItemEvent ->)
        item = TrayMenuItem.new(id, label, type, accelerator)
        item.on_click(&block)
        add_item(item)
      end

      # Appends a separator entry to the menu.
      def add_separator
        sep = TrayMenuItem.new("__sep_#{@items.size}", "", TrayMenuItemType::Separator)
        @items << sep
      end

      # Returns the number of entries (including separators) in the menu.
      def size : Int32
        @items.size
      end
    end

    # System tray (status-item) icon with a context menu and click events.
    #
    # All sensitive operations (creating the tray, updating the icon)
    # require the `tray` capability through the injected
    # `Security::CapabilitySystem`.
    #
    # ```
    # tray = CrystKit::Features::SystemTray.new(caps)
    # tray.menu do |m|
    #   m.add_item("quit", "Quit") { app.exit }
    #   m.add_separator
    #   m.add_item("about", "About…") { show_about }
    # end
    # tray.create(Path.new("icon.png"), tooltip: "My App")
    # ```
    class SystemTray
      Log = ::Log.for(self)

      # :nodoc:
      abstract class Provider
        abstract def create(app_id : String, icon : Platform::IconSource?, tooltip : String?) : Nil
        abstract def on_click(&block : Int32 ->) : Nil
        abstract def update_icon(icon : Platform::IconSource) : Nil
        abstract def set_menu(items : Array(Platform::TrayMenuEntry), callbacks : Hash(String, Proc(Nil))) : Nil
        abstract def tooltip=(text : String) : Nil
        abstract def destroy : Nil
      end

      # :nodoc:
      class NativeProvider < Provider
        def create(app_id : String, icon : Platform::IconSource?, tooltip : String?) : Nil
          ::NativeDesktop.tray.create(app_id, native_icon(icon), tooltip)
        end

        def on_click(&block : Int32 ->) : Nil
          ::NativeDesktop.tray.on_click { |button| block.call(button) }
        end

        def update_icon(icon : Platform::IconSource) : Nil
          ::NativeDesktop.tray.update_icon(native_icon(icon).not_nil!)
        end

        def set_menu(items : Array(Platform::TrayMenuEntry), callbacks : Hash(String, Proc(Nil))) : Nil
          ::NativeDesktop.tray.set_menu(native_items(items, callbacks))
        end

        def tooltip=(text : String) : Nil
          ::NativeDesktop.tray.tooltip = text
        end

        def destroy : Nil
          ::NativeDesktop.tray.destroy
        end

        private def native_icon(icon : Platform::IconSource?) : ::NativeDesktop::TrayIcon?
          return nil unless icon
          if bytes = icon.bytes
            ::NativeDesktop::TrayIcon.bytes(bytes, icon.key)
          elsif name = icon.name
            ::NativeDesktop::TrayIcon.name(name)
          end
        end

        private def native_items(
          entries : Array(Platform::TrayMenuEntry),
          callbacks : Hash(String, Proc(Nil)),
          parent_id : String = "",
        ) : Array(::NativeDesktop::TrayMenuItem)
          entries.select { |entry| entry[:parent_id] == parent_id }.map do |entry|
            type = case entry[:type]
                   when 1 then ::NativeDesktop::TrayMenuItemType::Checkbox
                   when 2 then ::NativeDesktop::TrayMenuItemType::Radio
                   when 3 then ::NativeDesktop::TrayMenuItemType::Separator
                   else        ::NativeDesktop::TrayMenuItemType::Normal
                   end
            ::NativeDesktop::TrayMenuItem.new(
              entry[:id],
              entry[:label],
              type,
              entry[:enabled] != 0,
              entry[:checked] != 0,
              entry[:accelerator],
              native_items(entries, callbacks, entry[:id]),
              callbacks[entry[:id]]?
            )
          end
        end
      end

      # Maximum tooltip text length in characters.
      # Longer strings raise `Core::Error` with code `TOOLTIP_TOO_LONG`.
      MAX_TOOLTIP_LENGTH = 256
      # Maximum icon file size in bytes (1 MiB).
      # Larger files raise with code `ICON_TOO_LARGE`.
      MAX_ICON_SIZE = 1_048_576 # 1 MB
      # Minimum accepted icon dimension in pixels.
      MIN_ICON_DIM = 16
      # Maximum accepted icon dimension in pixels.
      MAX_ICON_DIM = 256

      @capabilities : Security::CapabilitySystem
      @asset_source : AssetSource?
      @asset_fetcher : AssetFetcher?
      @menu : TrayMenu?
      @tooltip : String?
      @click_handler : Proc(MouseButton, Nil)?
      @created : Bool

      # Creates a tray controller. *app_id* defaults to
      # `CrystKit::AppConfig::DEFAULT_IDENTIFIER`.
      def initialize(
        @capabilities : Security::CapabilitySystem,
        @provider : Provider = NativeProvider.new,
        @app_id : String = CrystKit::AppConfig::DEFAULT_IDENTIFIER,
        asset_source : AssetSource? = nil,
        asset_fetcher : AssetFetcher? = nil,
      )
        @created = false
        @asset_source = asset_source
        @asset_fetcher = asset_fetcher
      end

      # Create the tray from a VFS path (sync).
      def create(icon : Path, tooltip : String? = nil) : Nil
        src = AssetResolution.resolve(icon, @asset_source)
        raise Core::Error.new("Icon not found: #{icon}", code: "ICON_NOT_FOUND") unless src
        validate_icon_source!(icon.to_s, src)
        validate_tooltip!(tooltip) if tooltip
        do_create(src, tooltip)
      end

      # Create the tray from a system theme icon name (sync, no format/size validation).
      def create(icon : String, tooltip : String? = nil) : Nil
        src = AssetResolution.resolve(icon, @asset_source)
        validate_tooltip!(tooltip) if tooltip
        do_create(src, tooltip)
      end

      # Create the tray from a network URL (async). The tray starts with
      # no icon; the framework calls update_icon when bytes arrive.
      def create(icon : URI, tooltip : String? = nil) : Nil
        fetcher = @asset_fetcher || raise Core::Error.new(
          "AssetFetcher required for URL icons", code: "ASSET_FETCHER_REQUIRED")
        validate_tooltip!(tooltip) if tooltip
        do_create(nil, tooltip)
        fetcher.fetch_async(icon,
          on_ready: ->(src : Platform::IconSource) {
            if b = src.bytes
              if b.size > MAX_ICON_SIZE
                Log.warn { "Tray: network icon exceeds MAX_ICON_SIZE (#{b.size} > #{MAX_ICON_SIZE}), skipping" }
              else
                platform_update_icon(src)
              end
            else
              platform_update_icon(src)
            end
          })
      end

      private def do_create(src : Platform::IconSource?, tooltip : String?) : Nil
        @tooltip = tooltip
        @created = true
        platform_create(src, tooltip)
        platform_wire_click

        # Apply menu if it was set before create was called
        if menu = @menu
          platform_set_menu(menu)
        end
      end

      # Sets the context *menu* on the tray.
      #
      # If the tray has already been created the menu is applied
      # immediately; otherwise it is queued and applied when `#create`
      # is next called.
      def menu=(menu : TrayMenu)
        @menu = menu
        platform_set_menu(menu) if @created
      end

      # Builds a `TrayMenu` via a block DSL and assigns it to the tray.
      # Yields the menu and returns it.
      def menu(& : TrayMenu -> _) : TrayMenu
        val = TrayMenu.new
        yield val
        self.menu = val
        val
      end

      # Replaces the tray icon with *icon* at runtime.
      # Raises with code `TRAY_NOT_CREATED` if the tray has not been created.
      def update_icon(icon : Path) : Nil
        raise Core::Error.new("Tray not created", code: "TRAY_NOT_CREATED") unless @created
        src = AssetResolution.resolve(icon, @asset_source)
        raise Core::Error.new("Icon not found: #{icon}", code: "ICON_NOT_FOUND") unless src
        validate_icon_source!(icon.to_s, src)
        platform_update_icon(src)
      end

      def update_icon(icon : String) : Nil
        raise Core::Error.new("Tray not created", code: "TRAY_NOT_CREATED") unless @created
        src = AssetResolution.resolve(icon, @asset_source)
        raise Core::Error.new("Icon not found: #{icon}", code: "ICON_NOT_FOUND") unless src
        platform_update_icon(src)
      end

      def update_icon(icon : URI) : Nil
        raise Core::Error.new("Tray not created", code: "TRAY_NOT_CREATED") unless @created
        fetcher = @asset_fetcher || raise Core::Error.new(
          "AssetFetcher required for URL icons", code: "ASSET_FETCHER_REQUIRED")
        fetcher.fetch_async(icon,
          on_ready: ->(src : Platform::IconSource) {
            if b = src.bytes
              if b.size > MAX_ICON_SIZE
                Log.warn { "Tray: network icon exceeds MAX_ICON_SIZE (#{b.size} > #{MAX_ICON_SIZE}), skipping" }
              else
                platform_update_icon(src)
              end
            else
              platform_update_icon(src)
            end
          })
      end

      # Sets the tooltip *text* (max `MAX_TOOLTIP_LENGTH` characters).
      #
      # If the tray has already been created the tooltip is applied
      # immediately; otherwise it is stored and applied on `#create`.
      # Raises `Core::Error` (code `TOOLTIP_TOO_LONG`) when the
      # text exceeds the limit.
      def tooltip=(text : String)
        validate_tooltip!(text)
        @tooltip = text
        platform_set_tooltip(text) if @created
      end

      # Registers *block* as the click handler for tray icon clicks.
      #
      # Only one handler is kept; registering a new one replaces the
      # previous.
      def on_click(&block : MouseButton ->)
        @click_handler = block
      end

      # Destroys the tray icon and removes it from the notification area.
      #
      # Safe to call when the tray was never created or already destroyed
      # (no-op). After destruction the instance can be reused by calling
      # `#create` again.
      def destroy
        return unless @created
        platform_destroy
        @created = false
      end

      # Returns `true` if the tray icon is currently created and visible.
      def created? : Bool
        @created
      end

      # :nodoc:
      #
      # Called internally when the tray icon is clicked.
      def handle_click(button : MouseButton)
        @click_handler.try(&.call(button))
      end

      private def validate_icon_source!(orig_path : String, src : Platform::IconSource) : Nil
        # Theme names skip format/size validation — the OS resolves them.
        return if src.name?

        # Bytes source (VFS or disk fallback): enforce size + PNG ext.
        size = @asset_source.try(&.size(orig_path)) ||
               (File.exists?(orig_path) ? File.size(orig_path) : nil)
        if size && size > MAX_ICON_SIZE
          raise Core::Error.new(
            "Icon size (#{size} bytes) exceeds maximum of #{MAX_ICON_SIZE} bytes",
            code: "ICON_TOO_LARGE")
        end
        unless orig_path.downcase.ends_with?(".png")
          raise Core::Error.new(
            "Icon must be in PNG format, got: #{orig_path}",
            code: "INVALID_ICON_FORMAT")
        end
      end

      # :nodoc:
      private def validate_tooltip!(text : String)
        if text.size > MAX_TOOLTIP_LENGTH
          raise Core::Error.new(
            "Tooltip text exceeds maximum length of #{MAX_TOOLTIP_LENGTH} characters",
            code: "TOOLTIP_TOO_LONG"
          )
        end
      end

      # :nodoc:
      private def platform_create(icon : Platform::IconSource?, tooltip : String?)
        ::CrystKit::Core::MainThread.dispatch_sync {
          @provider.create(@app_id, icon, tooltip)
        }
      end

      # :nodoc:
      private def platform_wire_click
        @provider.on_click do |btn|
          button = btn == 0 ? MouseButton::Left : MouseButton::Right
          handle_click(button)
        end
      end

      # :nodoc:
      private def platform_update_icon(icon : Platform::IconSource)
        ::CrystKit::Core::MainThread.dispatch_sync {
          @provider.update_icon(icon)
        }
      end

      # :nodoc:
      private def platform_set_menu(menu : TrayMenu)
        items = flatten_menu_items(menu)
        callbacks = {} of String => Proc(Nil)
        items.each do |entry|
          item = find_menu_item(menu, entry[:id])
          if item && item.type != TrayMenuItemType::Separator
            callbacks[entry[:id]] = -> { item.trigger_click }
          end
        end
        ::CrystKit::Core::MainThread.dispatch_sync {
          @provider.set_menu(items, callbacks)
        }
      end

      # :nodoc:
      private def platform_set_tooltip(text : String)
        ::CrystKit::Core::MainThread.dispatch_sync {
          @provider.tooltip = text
        }
      end

      # :nodoc:
      private def platform_destroy
        ::CrystKit::Core::MainThread.dispatch_sync {
          @provider.destroy
        }
      end

      # :nodoc:
      private def flatten_menu_items(menu : TrayMenu, parent_id : String = "") : Array(Platform::TrayMenuEntry)
        result = [] of Platform::TrayMenuEntry
        menu.items.each do |item|
          type_int = case item.type
                     when TrayMenuItemType::Checkbox  then 1
                     when TrayMenuItemType::Radio     then 2
                     when TrayMenuItemType::Separator then 3
                     else                                  0
                     end
          result << {id: item.id, label: item.label, type: type_int, enabled: item.enabled? ? 1 : 0, checked: item.checked? ? 1 : 0, parent_id: parent_id, accelerator: item.accelerator}
          if sub = item.submenu
            result.concat(flatten_menu_items(sub, item.id))
          end
        end
        result
      end

      # :nodoc:
      private def find_menu_item(menu : TrayMenu, id : String) : TrayMenuItem?
        menu.items.each do |item|
          return item if item.id == id
          if sub = item.submenu
            found = find_menu_item(sub, id)
            return found if found
          end
        end
        nil
      end
    end
  end
end
