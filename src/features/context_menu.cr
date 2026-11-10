require "json"
require "native_desktop"

module CrystKit::Features
  # Native context menu integration for webview right-click events.
  #
  # Custom menu items are gated behind the `context_menu:custom`
  # capability. When that capability is not granted, the `on_*`
  # registration helpers become no-ops, leaving only the default Cut /
  # Copy / Paste / Inspect items produced by the backend.
  class ContextMenu
    # :nodoc:
    Log = ::Log.for(self)

    # Handler block type invoked with a `ContextMenuBuilder` to populate.
    alias ItemHandler = Proc(CrystKit::Features::ContextMenuBuilder, Nil)

    # A single entry in a context menu.
    #
    # `Item` is the value type assembled by `ContextMenuBuilder` and
    # passed to the platform backend for rendering. Items are either
    # interactive (`Normal`, `Checkbox`), visual separators
    # (`Separator`), or parent entries that expand into a `submenu`.
    struct Item
      include JSON::Serializable

      # Stable identifier used to report the clicked item back to the
      # application. For `add` calls without an explicit *id*, the label
      # is lower-cased and spaces replaced with `-` to synthesise one.
      property id : String
      # User-visible label text shown by the platform menu.
      property label : String
      # Whether the item is clickable. Disabled items are rendered greyed-out.
      property? enabled : Bool
      # Whether a checkbox item is ticked. Ignored unless `#type` is `Checkbox`.
      property? checked : Bool
      # Rendering and behaviour class of the item.
      property type : Type
      # Optional nested items rendered as a submenu of this item.
      property submenu : Array(Item)?

      # Rendering and behaviour class of a menu `Item`.
      enum Type
        # A standard clickable menu entry.
        Normal
        # A non-interactive visual divider between groups of items.
        Separator
        # A toggleable entry with a check-mark state.
        Checkbox
      end

      # Creates a menu item with the given properties.
      #
      # Defaults produce a normal, enabled, unchecked item with no
      # submenu, suitable for the common `add(label)` case.
      def initialize(
        @id = "",
        @label = "",
        @enabled = true,
        @checked = false,
        @type = Type::Normal,
        @submenu : Array(Item)? = nil,
      )
      end
    end

    # Snapshot of the webview context in which a menu was invoked.
    #
    # `ContextData` is delivered to `ContextMenu#show` and to every
    # registered `on_*` handler. It carries the pointer coordinates of
    # the right-click plus high-level information about the DOM node
    # under the cursor (selection text, link URL, image source, element
    # name, editability), which the handler uses to decide which custom
    # items to add.
    struct ContextData
      # Horizontal coordinate of the invocation in webview logical pixels.
      getter x : Int32
      # Vertical coordinate of the invocation in webview logical pixels.
      getter y : Int32
      # Currently selected text in the webview, or `nil` if nothing is selected.
      getter selection : String?
      # `true` if the clicked element is an editable input field.
      getter? is_editable : Bool
      # URL of the anchor under the cursor, or `nil` if not on a link.
      getter link_url : String?
      # `src` URL of the image under the cursor, or `nil` if not on an image.
      getter image_src : String?
      # Lowercased DOM node name under the cursor (e.g. `"a"`, `"img"`), used by `on_element`.
      getter node_name : String?
      # Custom context name from `data-ctx` attribute on the target element, used by `on_context`.
      getter context_name : String?

      # Creates a context snapshot with the given webview state.
      def initialize(
        @x = 0,
        @y = 0,
        @selection = nil,
        @is_editable = false,
        @link_url = nil,
        @image_src = nil,
        @node_name = nil,
        @context_name = nil,
      )
      end
    end

    # Creates a context menu wired to *backend* and optionally gated by
    # *capabilities*.
    #
    # When *capabilities* is `nil`, the `on_*` registration helpers do not
    # enforce `context_menu:custom` — useful for tests. In production the
    # capability system should always be supplied so unauthorised code
    # cannot override native menu items.
    # :nodoc:
    abstract class Provider
      abstract def available? : Bool
      abstract def show(items : Array(Item), x : Int32, y : Int32, window_ptr : Void*) : String?
    end

    # :nodoc:
    class NativeProvider < Provider
      def available? : Bool
        ::NativeDesktop.context_menus.available?
      end

      def show(items : Array(Item), x : Int32, y : Int32, window_ptr : Void*) : String?
        native_items = items.map { |item| native_item(item) }
        ::NativeDesktop.context_menus.show(native_items, x, y, window_ptr)
      end

      private def native_item(item : Item) : ::NativeDesktop::ContextMenuItem
        type = case item.type
               when Item::Type::Separator then ::NativeDesktop::ContextMenuItemType::Separator
               when Item::Type::Checkbox  then ::NativeDesktop::ContextMenuItemType::Checkbox
               else                            ::NativeDesktop::ContextMenuItemType::Normal
               end
        submenu = item.submenu.try(&.map { |child| native_item(child) })
        ::NativeDesktop::ContextMenuItem.new(item.id, item.label, item.enabled?, item.checked?, type, submenu)
      end
    end

    def initialize(
      @provider : Provider = NativeProvider.new,
      @capabilities : Security::CapabilitySystem? = nil,
    )
      @handlers = [] of NamedTuple(priority: Int32, handler: ItemHandler, tag: String?)
    end

    # Register a handler invoked when the user right-clicks a text selection.
    #
    # Requires `context_menu:custom`. The handler runs only when the
    # invocation context has a non-empty `selection` and no more specific
    # handler (link/image) matches.
    def on_text_selection(&handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 30, handler: handler, tag: "text_selection"}
    end

    # Register a handler invoked when the user right-clicks an anchor (`<a>`).
    #
    # Requires `context_menu:custom`. Matches when `ContextData#link_url`
    # is present; has the highest selection priority (50) so it wins over
    # text-selection and image handlers on overlapping nodes.
    def on_link(&handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 50, handler: handler, tag: "link"}
    end

    # Register a handler invoked when the user right-clicks an image.
    #
    # Requires `context_menu:custom`. Matches when `ContextData#image_src`
    # is present. Priority 40.
    def on_image(&handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 40, handler: handler, tag: "image"}
    end

    # Register a handler invoked when the user right-clicks an element
    # with a matching `data-ctx` attribute.
    #
    # Requires `context_menu:custom`. Matches when `ContextData#context_name`
    # equals *name*. Priority 45 — higher than image/link so contextual
    # menus win over generic element matches.
    def on_context(name : String, &handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 45, handler: handler, tag: "ctx:#{name}"}
    end

    # Register a handler invoked when the user right-clicks an editable element.
    #
    # Requires `context_menu:custom`. Matches when `ContextData#is_editable?`
    # is `true`. Priority 35.
    def on_editable(&handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 35, handler: handler, tag: "editable"}
    end

    # Register a handler invoked when the user right-clicks an element whose
    # lowercased node name equals *tag* (e.g. `"video"`, `"canvas"`).
    #
    # Requires `context_menu:custom`. Priority 35, same as `on_editable`;
    # the first matching handler in insertion order wins among equal-priority
    # tags.
    def on_element(tag : String, &handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 35, handler: handler, tag: tag.downcase}
    end

    # Register a fallback handler invoked when no specific tag matches.
    #
    # Requires `context_menu:custom`. Priority 10 — the lowest — so any
    # matching specific handler wins first. There should normally be only
    # one default handler.
    def on_default(&handler : ItemHandler) : Nil
      @capabilities.try(&.require!("context_menu:custom"))
      @handlers << {priority: 10, handler: handler, tag: nil}
    end

    # Build the menu from the best-matching handler plus default items and
    # show it natively at the invocation coordinates.
    #
    # Returns the *id* of the item the user clicked, or `nil` if the menu
    # was dismissed without a selection. When no handler produces any items
    # and no defaults apply, returns `nil` without showing a menu.
    #
    # *window_ptr* is the opaque native window handle the backend renders
    # the menu against.
    def show(data : CrystKit::Features::ContextMenu::ContextData, window_ptr : Void*, debug : Bool = false) : String?
      builder = CrystKit::Features::ContextMenuBuilder.new(data)
      handler = find_handler(data)
      handler.try(&.call(builder))
      add_default_items(builder, data, debug)
      items = builder.items
      return nil if items.empty?
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.show(items, data.x, data.y, window_ptr)
      }
    end

    # Shows an already-built item list. Used by the context-menu plugin after
    # it appends browser-specific default actions.
    # :nodoc:
    def show_items(items : Array(Item), x : Int32, y : Int32, window_ptr : Void*) : String?
      return nil if items.empty?
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.show(items, x, y, window_ptr)
      }
    end

    # Populate *builder* with the items from the best-matching handler only,
    # without showing a menu or appending default items.
    #
    # Useful for inspecting or testing what a handler would produce.
    def build(data : CrystKit::Features::ContextMenu::ContextData, builder : CrystKit::Features::ContextMenuBuilder) : Nil
      handler = find_handler(data)
      handler.try(&.call(builder))
    end

    # Returns `true` if the platform backend can show native context menus.
    def available? : Bool
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.available?
      }
    end

    # :nodoc:
    private def find_handler(data : CrystKit::Features::ContextMenu::ContextData) : ItemHandler?
      sorted = @handlers.sort_by { |r| -r[:priority] }
      best = sorted.find { |r| match_handler?(r, data) && r[:tag] != nil }
      best ||= sorted.find { |r| r[:tag] == nil }
      best.try(&.[:handler])
    end

    # :nodoc:
    private def add_default_items(builder : CrystKit::Features::ContextMenuBuilder, data : CrystKit::Features::ContextMenu::ContextData, debug : Bool = false) : Nil
      if data.is_editable?
        has_sel = data.selection.try(&.empty?) == false
        builder.add("Cut", "cut") if has_sel
        builder.add("Copy", "copy")
        builder.add("Paste", "paste") unless has_sel
        builder.add("Select All", "select-all")
      elsif data.selection.try(&.empty?) == false
        builder.add("Copy", "copy")
      end
      builder.add_separator unless builder.items.empty?
      builder.add("Inspect Element", "inspect") if debug
    end

    # :nodoc:
    private def match_handler?(reg, data : CrystKit::Features::ContextMenu::ContextData) : Bool
      case reg[:tag]
      when nil
        true
      else
        tag = reg[:tag].not_nil!
        if tag.starts_with?("ctx:")
          data.context_name == tag[4..]
        else
          case tag
          when "link"           then !data.link_url.nil?
          when "image"          then !data.image_src.nil?
          when "editable"       then data.is_editable?
          when "text_selection" then data.selection.try(&.empty?) == false
          else                       tag == data.node_name.try(&.downcase)
          end
        end
      end
    end
  end

  # Fluent builder used to assemble context menu `Item` arrays.
  #
  # `ContextMenuBuilder` is handed to `on_*` handlers so application
  # code can populate the menu without touching the platform backend
  # directly. Each `add_*` helper appends one `Item` to `#items`; the
  # resulting array is then rendered by `ContextMenu#show`.
  #
  # ```
  # menu.on_link do |b|
  #   b.add("Open in New Tab", "open-tab")
  #   b.add("Copy Link", "copy-link")
  # end
  # ```
  class ContextMenuBuilder
    # The accumulated menu items, in insertion order.
    getter items : Array(CrystKit::Features::ContextMenu::Item)
    # The context snapshot this builder is populating a menu for.
    getter context : CrystKit::Features::ContextMenu::ContextData

    # Creates a fresh builder bound to *context* with an empty item list.
    def initialize(@context : CrystKit::Features::ContextMenu::ContextData)
      @items = [] of CrystKit::Features::ContextMenu::Item
    end

    # Append a normal menu entry.
    #
    # *label* is shown to the user; *id* is the identifier reported back
    # when the item is clicked. When *id* is empty, a slug is derived
    # from *label* by lower-casing and replacing runs of whitespace with
    # `-`. Pass *enabled* `false` to grey the item out, and *checked*
    # `true` only when paired with `add_checkbox` semantics.
    def add(label : String, id : String = "", enabled : Bool = true, checked : Bool = false) : Nil
      @items << CrystKit::Features::ContextMenu::Item.new(
        id: id.empty? ? label.downcase.gsub(/\s+/, "-") : id,
        label: label,
        enabled: enabled,
        checked: checked,
      )
    end

    # Append a checkbox-style menu entry with an explicit *id*.
    #
    # Checkbox items render with a tick mark when *checked* is `true`.
    # Unlike `#add`, *id* is required because checkbox state is
    # typically tracked by the application under a stable key.
    def add_checkbox(label : String, id : String, checked : Bool = false, enabled : Bool = true) : Nil
      @items << CrystKit::Features::ContextMenu::Item.new(
        id: id,
        label: label,
        enabled: enabled,
        checked: checked,
        type: CrystKit::Features::ContextMenu::Item::Type::Checkbox,
      )
    end

    # Append a non-interactive separator line between groups of items.
    def add_separator : Nil
      @items << CrystKit::Features::ContextMenu::Item.new(type: CrystKit::Features::ContextMenu::Item::Type::Separator)
    end

    # Append a submenu entry whose children are built by *block*.
    #
    # The block receives a fresh `ContextMenuBuilder` scoped to the same
    # `#context`; its `#items` become the submenu of the appended entry.
    # The submenu item's *id* is synthesised as `_submenu_<slug>`.
    def add_submenu(label : String, enabled : Bool = true, &block : CrystKit::Features::ContextMenuBuilder ->) : Nil
      sub_builder = CrystKit::Features::ContextMenuBuilder.new(@context)
      block.call(sub_builder)
      @items << CrystKit::Features::ContextMenu::Item.new(
        id: "_submenu_#{label.downcase.gsub(/\s+/, "-")}",
        label: label,
        enabled: enabled,
        submenu: sub_builder.items,
      )
    end
  end
end
