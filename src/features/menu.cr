require "log"
require "native_desktop"
require "./shortcuts"

module CrystKit
  module Features
    # Represents a single leaf item in an application menu.
    #
    # Carries the visible *label*, an optional platform *accelerator* string
    # (e.g. `"Cmd+O"`), and the *action* closure invoked when the user selects
    # the item. The *id* is a stable identifier used both for IPC dispatch and
    # for accelerator registration; when the caller omits it the framework
    # derives a kebab-case id from the label.
    #
    # Items flagged *global_accelerator* are additionally registered as
    # system-wide hotkeys by `MenuBar#wire_shortcuts`, allowing the shortcut
    # to fire even when the application is not focused.
    #
    # Separators are represented as `MenuItem`s whose `id` is the sentinel
    # `"__separator__"` and whose `label` is empty; they are produced by
    # `Menu#add_separator`.
    struct MenuItem
      # Stable identifier used for dispatch and accelerator registration.
      # Defaults to a kebab-case derivation of *label* when constructed
      # via `Menu#add_item`.
      property id : String
      # The user-visible label text.
      property label : String
      # When `false` the item renders greyed-out and is non-activatable.
      property? enabled : Bool
      # When `true` the item renders with a checkmark on platforms that
      # support checkable menu items.
      property? checked : Bool
      # Accelerator string (e.g. `"Cmd+O"`) shown beside the label, or
      # `nil` when the item has no keyboard shortcut.
      property accelerator : String?
      # The closure invoked when the user selects the item. `nil` items
      # (typically separators) have no action.
      property action : Proc(Nil)?
      # When `true`, `MenuBar#wire_shortcuts` registers *accelerator* as a
      # system-wide hotkey so the item fires even when the app is unfocused.
      property? global_accelerator : Bool

      # Creates a menu item with the given properties.
      #
      # Direct construction is uncommon — `Menu#add_item` builds items with a
      # derived id. Use the constructor directly when you need a sentinel
      # (e.g. separators) or want to defer action assignment.
      def initialize(
        @id = "",
        @label = "",
        @enabled = true,
        @checked = false,
        @accelerator = nil,
        @action : Proc(Nil)? = nil,
        @global_accelerator = false,
      )
      end
    end

    # Represents a menu (File, Edit, View, etc.) containing items and submenus.
    #
    # A hierarchical container: its `#items` array holds either `MenuItem`
    # leaves or nested `Menu` instances, allowing arbitrarily-deep menus like
    # "File → New → Window". All builder methods (`#add_item`, `#add_separator`,
    # `#add_submenu`) return `self` so a menu can be assembled in a fluent chain.
    #
    # The *id* is optional metadata available for automation/IPC identification;
    # it is not used for dispatch on most platforms.
    class Menu
      # Stable identifier (optional; empty by default).
      property id : String
      # The user-visible label of the menu (e.g. "File").
      property label : String
      # The ordered children — `MenuItem` leaves and nested `Menu` submenus —
      # in display order. Prefer `#add_item` and friends over mutating this
      # array directly.
      getter items : Array(MenuItem | Menu)

      # Creates an empty menu labelled *label* with optional *id*.
      def initialize(@label : String, @id = "")
        @items = [] of MenuItem | Menu
      end

      # Appends a leaf item to the menu and registers *action* as its
      # handler, returning `self` for chaining.
      #
      # When *id* is empty the framework derives one from *label* by
      # lowercasing and replacing whitespace with dashes (e.g. "Open…" →
      # `"open…"`). Pass *accelerator* to display a keyboard shortcut beside
      # the label; pass *global_accelerator* `true` to have
      # `MenuBar#wire_shortcuts` register the shortcut system-wide.
      def add_item(label : String, accelerator : String? = nil, id : String = "", global_accelerator : Bool = false, &action : -> Nil) : self
        @items << MenuItem.new(
          id: id.empty? ? label.downcase.gsub(/\s+/, "-") : id,
          label: label,
          accelerator: accelerator,
          action: action,
          global_accelerator: global_accelerator,
        )
        self
      end

      # Alias of `#add_item` for syntactic closeness with `MenuBar#menu`.
      def item(label : String, accelerator : String? = nil, id : String = "", global_accelerator : Bool = false, &action : -> Nil) : self
        add_item(label, accelerator, id, global_accelerator, &action)
      end

      # Appends a horizontal separator (a `MenuItem` with the sentinel id
      # `"__separator__"` and empty label).
      #
      # Separators have no *action*, no accelerator, and are skipped by
      # `MenuBar#wire_shortcuts`.
      def add_separator : self
        @items << MenuItem.new(id: "__separator__", label: "")
        self
      end

      # Appends *menu* as a nested submenu.
      #
      # The submenu's existing items are preserved (not cloned), so subsequent
      # in-place mutation of *menu* is visible through the parent. Returns
      # `self` for chaining.
      def add_submenu(menu : Menu) : self
        @items << menu
        self
      end

      # Alias of `#add_submenu`.
      def add_menu(menu : Menu) : self
        add_submenu(menu)
      end
    end

    # The application menu bar.
    #
    # The top-level container of `Menu`s. Provides the entry point for
    # wiring global keyboard shortcuts through `#wire_shortcuts`, and a
    # `MenuBar.standard` factory that returns a canonical macOS-style
    # application menu layout.
    #
    # Usage:
    # ```
    # menu_bar = CrystKit::Features::MenuBar.new
    # file_menu = CrystKit::Features::Menu.new("File")
    # file_menu.add_item("Open", "Cmd+O") { puts "Open" }
    # file_menu.add_separator
    # file_menu.add_item("Quit", "Cmd+Q") { app.quit }
    # menu_bar.add(file_menu)
    # app.menu_bar = menu_bar
    # ```
    class MenuBar
      Log = ::Log.for(self)

      # Internal seam used by CrystKit specs.
      # :nodoc:
      abstract class Provider
        abstract def requires_running_event_loop? : Bool
        abstract def install(menu_bar : MenuBar, window_ptr : Void*?) : Nil
      end

      # :nodoc:
      class NativeProvider < Provider
        def requires_running_event_loop? : Bool
          ::NativeDesktop.application_menus.requires_running_event_loop?
        end

        def install(menu_bar : MenuBar, window_ptr : Void*?) : Nil
          native_menus = menu_bar.menus.map { |menu| native_menu(menu) }
          ::NativeDesktop.application_menus.install(::NativeDesktop::MenuBar.new(native_menus), window_ptr)
        end

        private def native_menu(menu : Menu) : ::NativeDesktop::Menu
          entries = menu.items.map do |entry|
            case entry
            in Menu
              native_menu(entry)
            in MenuItem
              if entry.id == "__separator__"
                ::NativeDesktop::MenuSeparator.new
              else
                ::NativeDesktop::MenuItem.new(
                  entry.id,
                  entry.label,
                  entry.enabled?,
                  entry.checked?,
                  entry.accelerator,
                  entry.action
                )
              end
            end
          end
          ::NativeDesktop::Menu.new(menu.label, menu.id, entries)
        end
      end

      # The top-level menus in display order.
      getter menus : Array(Menu)

      # Creates an empty menu bar.
      def initialize(@provider : Provider = NativeProvider.new)
        @menus = [] of Menu
      end

      # Appends *menu* as a top-level menu, returning `self` for chaining.
      def add(menu : Menu) : self
        @menus << menu
        self
      end

      # Builds a new `Menu` labelled *label*, yields it to *block* so the
      # caller can populate it with `Menu#add_item`/`#add_separator`,
      # adds it to this bar, and returns the constructed menu.
      #
      # This is the ergonomic shortcut for inlining a menu definition:
      #
      # ```
      # menu_bar.menu("File") do |m|
      #   m.add_item("Open", "Cmd+O") { open_doc }
      #   m.add_separator
      # end
      # ```
      def menu(label : String, id : String = "", &block : Menu ->) : Menu
        menu = Menu.new(label, id)
        block.call(menu)
        add(menu)
        menu
      end

      # Install this menu bar on the current platform.
      #
      # On macOS this sets the global application menu bar. On Linux and
      # Windows it attaches the menu to the given window (or the global
      # menu bar if no window pointer is provided).
      def install(window_ptr : Void*? = nil) : Nil
        @provider.install(self, window_ptr)
      end

      # :nodoc:
      def requires_running_event_loop? : Bool
        @provider.requires_running_event_loop?
      end

      # Register all items with `global_accelerator` set to true as global
      # shortcuts. Returns a `GlobalShortcuts` instance if any items were
      # registered, or `nil`.
      def wire_shortcuts : GlobalShortcuts?
        shortcuts = GlobalShortcuts.new
        count = register_shortcuts(shortcuts)
        if count > 0
          @global_shortcuts = shortcuts
          shortcuts
        else
          nil
        end
      end

      # :nodoc:
      private def register_shortcuts(shortcuts : GlobalShortcuts) : Int32
        count = 0
        @menus.each do |menu|
          count += walk_and_register(menu, shortcuts)
        end
        count
      end

      # The `GlobalShortcuts` instance created by the last successful
      # `#wire_shortcuts` call, or `nil` if shortcuts have not been wired.
      property global_shortcuts : GlobalShortcuts?

      # :nodoc:
      private def walk_and_register(menu : Menu, shortcuts : GlobalShortcuts) : Int32
        count = 0
        menu.items.each do |item|
          case item
          in MenuItem
            if item.global_accelerator? && (accel = item.accelerator) && (action = item.action)
              begin
                shortcuts.register(accel, &action)
                count += 1
              rescue
              end
            end
          in Menu
            count += walk_and_register(item, shortcuts)
          end
        end
        count
      end

      # Build a standard application menu (macOS convention).
      def self.standard(app_name : String = "App") : MenuBar
        mb = new

        # App menu (macOS only — other platforms skip)
        app_menu = Menu.new(app_name)
        app_menu.add_item("About #{app_name}", id: "about") { }
        app_menu.add_separator
        app_menu.add_item("Preferences...", "Cmd+,", id: "preferences") { }
        app_menu.add_separator
        app_menu.add_item("Quit #{app_name}", "Cmd+Q", id: "quit") { }
        mb.add(app_menu)

        # File menu
        file_menu = Menu.new("File")
        file_menu.add_item("New Window", "Cmd+N", id: "new-window") { }
        file_menu.add_item("Open...", "Cmd+O", id: "open") { }
        file_menu.add_separator
        file_menu.add_item("Close", "Cmd+W", id: "close") { }
        mb.add(file_menu)

        # Edit menu
        edit_menu = Menu.new("Edit")
        edit_menu.add_item("Undo", "Cmd+Z", id: "undo") { }
        edit_menu.add_item("Redo", "Cmd+Shift+Z", id: "redo") { }
        edit_menu.add_separator
        edit_menu.add_item("Cut", "Cmd+X", id: "cut") { }
        edit_menu.add_item("Copy", "Cmd+C", id: "copy") { }
        edit_menu.add_item("Paste", "Cmd+V", id: "paste") { }
        edit_menu.add_item("Select All", "Cmd+A", id: "select-all") { }
        mb.add(edit_menu)

        # View menu
        view_menu = Menu.new("View")
        view_menu.add_item("Toggle Developer Tools", "Cmd+Alt+I", id: "devtools") { }
        view_menu.add_item("Reload", "Cmd+R", id: "reload") { }
        view_menu.add_item("Toggle Fullscreen", "Cmd+Ctrl+F", id: "fullscreen") { }
        mb.add(view_menu)

        # Window menu
        window_menu = Menu.new("Window")
        window_menu.add_item("Minimize", "Cmd+M", id: "minimize") { }
        window_menu.add_item("Zoom", id: "zoom") { }
        mb.add(window_menu)

        # Help menu
        help_menu = Menu.new("Help")
        help_menu.add_item("Documentation", id: "docs") { }
        help_menu.add_item("Report an Issue...", id: "report-issue") { }
        mb.add(help_menu)

        mb
      end
    end
  end
end
