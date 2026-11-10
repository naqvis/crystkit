require "../base"
require "../../features/context_menu"

module CrystKit
  module Plugins
    # Plugin that replaces the webview's native context menu with a
    # platform-rendered one driven by frontend IPC.
    #
    # Registers IPC commands:
    #   contextmenu.show — Build and display the native context menu
    #
    # Emits events: contextmenu.action
    #
    # `contextmenu.show` is contextual: it receives the live `IPC::Context` so
    # the platform menu can be anchored to the calling window's native handle.
    # Built-in ids (`cut`, `copy`, `paste`, `select-all`, `inspect`) are handled
    # client-side; any other id is emitted as a `contextmenu.action` event.
    class ContextMenu < Plugin::Base
      getter! context_menu : Features::ContextMenu

      # JavaScript bridge injected into every window to intercept the
      # `contextmenu` event and forward context data to `contextmenu.show`.
      CONTEXT_MENU_JS = <<-JS
        (function() {
          if (window.__crystkit_contextmenu_injected) return;
          window.__crystkit_contextmenu_injected = true;

          var defaults = {
            'cut': function() { document.execCommand('cut'); },
            'copy': function() { document.execCommand('copy'); },
            'paste': function() { document.execCommand('paste'); },
            'select-all': function() { document.execCommand('selectAll'); },
            'inspect': function() {
              if (window.__CRYSTKIT_IPC__) {
                window.__CRYSTKIT_IPC__.invoke('devtools.toggle');
              }
            }
          };

          var _ctxHandled = false;

          function collectMenuData(e) {
            var target = e.target;
            var linkEl = target.closest ? target.closest('a') : null;
            var imgEl = target.closest ? target.closest('img') : null;
            var ctxEl = target.closest ? target.closest('[data-ctx]') : null;
            return {
              x: e.clientX,
              y: e.clientY,
              selection: window.getSelection().toString(),
              isEditable: target.isContentEditable ||
                          (['INPUT', 'TEXTAREA'].indexOf(target.tagName) !== -1),
              linkUrl: linkEl ? linkEl.href : null,
              imageSrc: imgEl ? imgEl.src : null,
              nodeName: target.nodeName,
              contextName: ctxEl ? ctxEl.getAttribute('data-ctx') : null
            };
          }

          function showMenu(data) {
            if (!window.__CRYSTKIT_IPC__) return;
            window.__CRYSTKIT_IPC__.invoke('contextmenu.show', data).then(function(result) {
              if (!result || !result.item_id) return;
              var id = result.item_id;
              if (defaults[id]) {
                defaults[id]();
              } else {
                window.__CRYSTKIT_IPC__.emit('contextmenu.action', { item_id: id }).catch(function(err) {
              console.error('[CrystKit ContextMenu] emit contextmenu.action failed:', err.message || err);
            });
              }
            }).catch(function(err) {
              console.error('[CrystKit ContextMenu] invoke error:', err);
            });
          }

          document.addEventListener('contextmenu', function(e) {
            _ctxHandled = true;
            e.preventDefault();
            showMenu(collectMenuData(e));
          }, false);

          window.addEventListener('mouseup', function(e) {
            if (e.button !== 2) return;
            var data = collectMenuData(e);
            Promise.resolve().then(function() {
              if (_ctxHandled) { _ctxHandled = false; return; }
              showMenu(data);
            });
          });
        })();
      JS

      def identifier : String
        "context_menu"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(contextmenu.show contextmenu.build), "context_menu:custom")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(context_menu:custom context_menu:inspect),
          commands: %w(contextmenu.show contextmenu.build),
          events: %w(contextmenu.action),
          frontend_events: %w(contextmenu.action),
          ipc: ipc,
        )
      end

      # `contextmenu.show` receives the per-call `IPC::Context` and returns the
      # chosen item id as `{"item_id" => ...}`.
      def initialize_plugin(context : Plugin::Context) : Nil
        @context = context
        @context_menu = Features::ContextMenu.new(
          capabilities: context.app.runtime.security.capabilities,
        )

        # Echo frontend-emitted contextmenu.action events back to all
        # frontend windows so ipc.listen subscribers in app JS receive them.
        context.app.on("contextmenu.action") do |payload|
          context.app.bridge_event_to_frontend("contextmenu.action", payload)
        end

        context.command "contextmenu.build", JSON::Any do |items_json|
          @js_items = items_json.as_a.map { |entry| parse_menu_item(entry) }
        end

        context.command_context "contextmenu.show" do |ipc_ctx, params|
          data = Features::ContextMenu::ContextData.new(
            x: params["x"]?.try(&.as_i) || 0,
            y: params["y"]?.try(&.as_i) || 0,
            selection: params["selection"]?.try(&.as_s?),
            is_editable: params["isEditable"]?.try(&.as_bool) || false,
            link_url: params["linkUrl"]?.try(&.as_s?),
            image_src: params["imageSrc"]?.try(&.as_s?),
            node_name: params["nodeName"]?.try(&.as_s?),
            context_name: params["contextName"]?.try(&.as_s?),
          )

          window_ptr = ipc_ctx.window.try(&.window) || Pointer(Void).null

          debug = ipc_ctx.window.try(&.debug?) || false

          item_id = if js = @js_items
                      show_js_items(js, data, window_ptr, debug)
                    else
                      context_menu.show(data, window_ptr, debug)
                    end

          context.app.coerce_to_json({"item_id" => item_id})
        end
      end

      def on_window_created(window : CrystKit::Core::Window) : Nil
        window.init(CONTEXT_MENU_JS)
      end

      # Parse a single JSON entry into a ContextMenu::Item.
      private def parse_menu_item(entry : JSON::Any) : Features::ContextMenu::Item
        id = entry["id"]?.try(&.as_s) || ""
        label = entry["label"]?.try(&.as_s) || ""
        enabled = entry["enabled"]?.try(&.as_bool) || true
        checked = entry["checked"]?.try(&.as_bool) || false
        item_type = entry["type"]?.try(&.as_s) || "normal"

        type = case item_type
               when "separator" then Features::ContextMenu::Item::Type::Separator
               when "checkbox"  then Features::ContextMenu::Item::Type::Checkbox
               else                  Features::ContextMenu::Item::Type::Normal
               end

        submenu = entry["submenu"]?.try(&.as_a).try(&.map { |sub| parse_menu_item(sub) })

        Features::ContextMenu::Item.new(
          id: id,
          label: label,
          enabled: enabled,
          checked: checked,
          type: type,
          submenu: submenu,
        )
      end

      # Show a context menu built from JS-provided items, with default
      # browser items (Cut/Copy/Paste/Inspect) appended automatically.
      private def show_js_items(items : Array(Features::ContextMenu::Item), data : Features::ContextMenu::ContextData, window_ptr : Void*, debug : Bool = false) : String?
        all_items = items + default_browser_items(data, debug)
        return nil if all_items.empty?
        @context_menu.not_nil!.show_items(all_items, data.x, data.y, window_ptr)
      end

      # Standard browser default items (Cut/Copy/Paste/Inspect).
      # Inspect Element is only included when *debug* is true.
      private def default_browser_items(data : Features::ContextMenu::ContextData, debug : Bool = false) : Array(Features::ContextMenu::Item)
        items = [] of Features::ContextMenu::Item
        if data.is_editable?
          has_sel = data.selection.try(&.empty?) == false
          items << Features::ContextMenu::Item.new(id: "cut", label: "Cut") if has_sel
          items << Features::ContextMenu::Item.new(id: "copy", label: "Copy")
          items << Features::ContextMenu::Item.new(id: "paste", label: "Paste") unless has_sel
          items << Features::ContextMenu::Item.new(id: "select-all", label: "Select All")
        elsif data.selection.try(&.empty?) == false
          items << Features::ContextMenu::Item.new(id: "copy", label: "Copy")
        end
        items << Features::ContextMenu::Item.new(type: Features::ContextMenu::Item::Type::Separator) unless items.empty?
        items << Features::ContextMenu::Item.new(id: "inspect", label: "Inspect Element") if debug
        items
      end

      def cleanup_plugin : Nil
        @context = nil
        @js_items = nil
      end

      # Items provided by the JS frontend via `contextmenu.build`.
      # When non-nil these override the Crystal-side on_* handlers.
      @js_items : Array(Features::ContextMenu::Item)?

      # :nodoc:
      @context : Plugin::Context?
    end
  end
end
