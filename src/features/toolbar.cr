require "log"
require "native_desktop"
require "../core/errors"
require "../security/capability"
require "../platform/icon_source"
require "./asset_resolution"
require "./asset_source"
require "./asset_fetcher"

module CrystKit::Features
  # Visual style applied to a window toolbar.
  enum ToolbarStyle
    Default
    Dark
    Light
    Transparent
  end

  # The visual and interactive type of a toolbar item.
  enum ToolbarItemType
    # A standard push button.
    Button
    # A two-state toggle button that retains its pressed/released state.
    Toggle
    # A dropdown/popup button that presents a list of selectable options.
    Dropdown
    # A color swatch that opens a native color picker on click.
    Color
  end

  # A single toolbar button or control.
  #
  # Separators are represented as items with the sentinel id
  # `"__separator__"` and no action.
  struct ToolbarItem
    # Stable identifier for this item, unique within its toolbar.
    getter id : String
    # Human-readable label shown beneath or beside the icon.
    getter label : String
    # The original icon argument as passed to the builder (name, path, or
    # URL string). Preserved for re-resolution and IPC serialization.
    getter icon_arg : String?
    # Resolved IconSource (bytes from VFS/disk, or theme name), or nil for
    # text-only items.
    getter icon : ::CrystKit::Platform::IconSource?
    # Returns `true` when the item is interactive (not greyed out).
    getter? enabled : Bool
    # Returns `true` when a toggle/checkbox item is currently selected.
    getter? checked : Bool
    # The item type (button, toggle, or dropdown).
    getter item_type : ToolbarItemType
    # Available options for a dropdown item; empty for non-dropdown items.
    getter options : Array(String)
    # Index of the currently selected option in a dropdown item.
    getter selected_index : Int32
    # Hex color string (e.g. "#FF0000") for a color picker item.
    getter color : String
    # Proc invoked when the user activates this item, or `nil` for separators.
    getter action : Proc(Nil)?

    # Creates a toolbar item.
    def initialize(@id : String, @label : String, @icon_arg : String? = nil,
                   @icon : ::CrystKit::Platform::IconSource? = nil,
                   @enabled = true, @checked = false,
                   @item_type : ToolbarItemType = ToolbarItemType::Button,
                   @options = [] of String,
                   @selected_index = 0,
                   @color = "",
                   @action : Proc(Nil)? = nil)
    end
  end

  # An ordered collection of toolbar items with style and visibility control.
  #
  # ```
  # toolbar = CrystKit::Features::Toolbar.new
  # toolbar.title = "Document"
  # toolbar.add_item("save", "Save") { save_document }
  # toolbar.add_separator
  # toolbar.add_item("print", "Print") { print_document }
  # toolbar.style = ToolbarStyle::Dark
  # ```
  class Toolbar
    # :nodoc:
    Log = ::Log.for(self)

    @items : Array(ToolbarItem)
    @visible : Bool
    @style : ToolbarStyle
    @title : String
    @asset_source : AssetSource?
    @asset_fetcher : AssetFetcher?
    getter icon_dir : String?

    # Sets the icon directory and re-resolves existing item icons.
    def icon_dir=(dir : String?) : String?
      @icon_dir = dir
      resolve_item_icons
      sync
      @icon_dir
    end

    # Re-resolves all item icons against the current icon_dir.
    private def resolve_item_icons : Nil
      @items.map! { |item|
        icon = self.class.resolve_icon(item.icon_arg, @icon_dir, @asset_source)
        ToolbarItem.new(id: item.id, label: item.label, icon_arg: item.icon_arg, icon: icon,
          enabled: item.enabled?, checked: item.checked?,
          item_type: item.item_type, options: item.options,
          selected_index: item.selected_index, color: item.color,
          action: item.action)
      }
    end

    # Resolve an icon argument to an IconSource for a toolbar item.
    #   - String containing '/' (looks like a path) -> VFS lookup, then
    #     icon_dir on-disk fallback.
    #   - String with no slash -> theme name (IconSource.name).
    #   - nil -> nil.
    #
    # URI icons are handled separately by the builders (async via
    # AssetFetcher); this method doesn't handle URIs.
    def self.resolve_icon(arg : String?, icon_dir : String?,
                          source : AssetSource?) : ::CrystKit::Platform::IconSource?
      return nil if arg.nil? || arg.empty?
      # The VFS is the authority: if a source is wired in and has the
      # file, treat as VFS path. Otherwise check icon_dir on disk. If
      # neither has it, treat as a theme name.
      if source && source.exists?(arg)
        if bytes = source.read_bytes(arg)
          return ::CrystKit::Platform::IconSource.bytes(bytes, key: arg)
        end
      end
      if icon_dir
        filename = %w(svg png ico jpg jpeg gif).any? { |ext| arg.ends_with?(".#{ext}") } ? arg : "#{arg}.svg"
        full = ::File.join(icon_dir, filename)
        if ::File.exists?(full)
          return ::CrystKit::Platform::IconSource.bytes(::File.read(full).to_slice, key: full)
        end
      end
      ::CrystKit::Platform::IconSource.name(arg)
    end

    # :nodoc:
    abstract class Provider
      abstract def register(native_handle : Void*, content_handle : Void*, toolbar : Toolbar) : Nil
      abstract def update_items(items : Array(ToolbarItem)) : Nil
      abstract def visible=(visible : Bool) : Nil
      abstract def cleanup : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      @toolbar : ::NativeDesktop::Toolbar?

      def register(native_handle : Void*, content_handle : Void*, toolbar : Toolbar) : Nil
        native = ::NativeDesktop::Toolbar.new(
          toolbar.items.map { |item| native_item(item) },
          ::NativeDesktop::ToolbarStyle.from_value(toolbar.style.value),
          toolbar.title,
          toolbar.visible?
        )
        native.attach(native_handle, content_handle.null? ? nil : content_handle)
        @toolbar = native
      end

      def update_items(items : Array(ToolbarItem)) : Nil
        return unless toolbar = @toolbar
        toolbar.items.clear
        toolbar.items.concat(items.map { |item| native_item(item) })
        toolbar.sync
      end

      def visible=(visible : Bool) : Nil
        @toolbar.try { |toolbar| toolbar.visible = visible }
      end

      def cleanup : Nil
        @toolbar.try(&.cleanup)
        @toolbar = nil
      end

      private def native_item(item : ToolbarItem) : ::NativeDesktop::ToolbarItem
        icon = if source = item.icon
                 if bytes = source.bytes
                   ::NativeDesktop::ToolbarIcon.bytes(bytes, source.key)
                 elsif name = source.name
                   ::NativeDesktop::ToolbarIcon.name(name)
                 end
               end
        type = item.id == "__separator__" ? ::NativeDesktop::ToolbarItemType::Separator : ::NativeDesktop::ToolbarItemType.from_value(item.item_type.value)
        ::NativeDesktop::ToolbarItem.new(
          item.id, item.label, icon, item.enabled?, item.checked?, type,
          item.options, item.selected_index, item.color, item.action
        )
      end
    end

    # Creates an empty toolbar.
    #
    def initialize(@capabilities : Security::CapabilitySystem? = nil,
                   @provider : Provider = NativeProvider.new,
                   asset_source : AssetSource? = nil,
                   asset_fetcher : AssetFetcher? = nil)
      @items = [] of ToolbarItem
      @visible = true
      @style = ToolbarStyle::Default
      @title = ""
      @icon_dir = nil
      @asset_source = asset_source
      @asset_fetcher = asset_fetcher
      @owner_window_id = nil
    end

    # Registers this toolbar on a native window. Returns `false` when the
    # toolbar already belongs to another window or the native handle is not
    # ready.
    def install(window : Core::Window) : Bool
      if owner = @owner_window_id
        return owner == window.id
      end

      native = window.window
      @owner_window_id = window.id
      return true if native.null?
      content = window.native_handle(::Webview::NativeHandleKind::UI_WIDGET)
      @provider.register(native, content, self)
      true
    end

    # Pushes the current item list to the native backend.
    def sync : Nil
      @provider.update_items(@items)
    end

    # Shows or hides the native toolbar.
    def native_visible=(visible : Bool) : Nil
      @provider.visible = visible
    end

    # Releases native toolbar resources owned by the backend.
    def cleanup : Nil
      @provider.cleanup
    end

    # Appends an actionable item to the toolbar and returns `self` for chaining.
    #
    # The *id* should be unique within this toolbar; duplicate ids may
    # collide when rendered natively.
    def add_item(id : String, label : String, icon : String? = nil,
                 &action : -> Nil) : self
      resolved = self.class.resolve_icon(icon, @icon_dir, @asset_source)
      @items << ToolbarItem.new(id: id, label: label, icon_arg: icon, icon: resolved, action: action)
      self
    end

    # Appends a toggle item to the toolbar and returns `self` for chaining.
    #
    # A toggle retains its checked state visually when clicked.
    def add_toggle(id : String, label : String, icon : String? = nil,
                   checked = false, &action : -> Nil) : self
      resolved = self.class.resolve_icon(icon, @icon_dir, @asset_source)
      @items << ToolbarItem.new(id: id, label: label, icon_arg: icon, icon: resolved,
        checked: checked,
        item_type: ToolbarItemType::Toggle,
        action: action)
      self
    end

    # Appends a dropdown item to the toolbar and returns `self` for chaining.
    #
    # The dropdown presents *options* for the user to select from.
    def add_dropdown(id : String, label : String, icon : String? = nil,
                     options : Array(String) = [] of String,
                     selected_index = 0, &action : -> Nil) : self
      resolved = self.class.resolve_icon(icon, @icon_dir, @asset_source)
      @items << ToolbarItem.new(id: id, label: label, icon_arg: icon, icon: resolved,
        item_type: ToolbarItemType::Dropdown,
        options: options,
        selected_index: selected_index,
        action: action)
      self
    end

    # Appends a color picker item to the toolbar and returns `self`.
    #
    # *color* is a hex string like `"#FF0000"`.
    def add_color(id : String, label : String, color : String = "",
                  &action : -> Nil) : self
      @items << ToolbarItem.new(id: id, label: label,
        item_type: ToolbarItemType::Color,
        color: color,
        action: action)
      self
    end

    # Appends a visual separator to the toolbar and returns `self`.
    def add_separator : self
      @items << ToolbarItem.new(id: "__separator__", label: "|")
      self
    end

    # Removes every item whose id equals *id*. Idempotent.
    def remove_item(id : String) : Nil
      @items.reject! { |item| item.id == id }
    end

    # Removes all items from the toolbar.
    def clear : Nil
      @items.clear
    end

    # Update a single item's icon (used by the async network fetch path).
    # Swaps the icon in-place and syncs to the native backend.
    def swap_item_icon(item_id : String, icon_source : ::CrystKit::Platform::IconSource) : Nil
      idx = @items.index { |i| i.id == item_id }
      return unless idx
      old = @items[idx]
      @items[idx] = ToolbarItem.new(
        id: old.id, label: old.label, icon_arg: old.icon_arg, icon: icon_source,
        enabled: old.enabled?, checked: old.checked?,
        item_type: old.item_type, options: old.options,
        selected_index: old.selected_index, color: old.color,
        action: old.action,
      )
      sync
    end

    # Returns a copy of the items in this toolbar.
    def items : Array(ToolbarItem)
      @items.dup
    end

    # Marks the toolbar as visible.
    def show : Nil
      @visible = true
    end

    # Marks the toolbar as hidden.
    def hide : Nil
      @visible = false
    end

    # Returns `true` when the toolbar is currently marked visible.
    def visible? : Bool
      @visible
    end

    # Returns the toolbar's visual style.
    def style : ToolbarStyle
      @style
    end

    # Sets the toolbar's visual style.
    def style=(s : ToolbarStyle) : Nil
      @style = s
    end

    # Returns the toolbar's title text.
    def title : String
      @title
    end

    # Sets the toolbar's title text.
    def title=(t : String) : Nil
      @title = t
    end
  end
end
