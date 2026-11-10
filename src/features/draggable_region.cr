module CrystKit
  module Features
    # Provides draggable region support for frameless windows.
    #
    # Produces the JavaScript bridge injected into the webview to let the user
    # move a frameless window by dragging specific elements. The application
    # is responsible for injecting `#js_bridge` and for handling the resulting
    # `window:move_by` IPC calls in its window controller.
    #
    # Two opt-in mechanisms are supported:
    #
    # * the `data-cryst-drag` attribute on any element, and
    # * the `-webkit-app-region: drag` CSS property (inline or computed).
    #
    # Usage (frontend HTML):
    #   <div data-cryst-drag>Title Bar</div>
    class DraggableRegion
      Log = ::Log.for(self)

      # Returns the JavaScript snippet to inject for draggable regions.
      #
      # Safe to inject multiple times. Recognises drag handles via either
      # `data-cryst-drag` or `-webkit-app-region: drag`. On a left-button drag,
      # forwards incremental deltas to the CrystKit IPC bridge as
      # `window:move_by` invocations with `{x, y}` payloads. A global
      # `__crystkit_drag_disabled` flag can be set to `true` to temporarily
      # suspend dragging.
      def self.js_bridge : String
        <<-JS
          (function(){
            if (window.__crystkit_drag_installed) return;
            window.__crystkit_drag_installed = true;
            window.__crystkit_drag_disabled = false;
            var isDragging = false;
            var startX, startY;

            function isDragHandle(el) {
              if (!el) return false;
              var target = el.closest('[data-cryst-drag]');
              if (target) return true;
              while (el) {
                try {
                  var cs = window.getComputedStyle(el);
                  if (cs.getPropertyValue('-webkit-app-region') === 'drag') return true;
                } catch(e) {}
                el = el.parentElement;
              }
              return false;
            }

            document.addEventListener('mousedown', function(e) {
              if (window.__crystkit_drag_disabled) return;
              if (e.button !== 0) return;
              if (!isDragHandle(e.target)) return;
              isDragging = true;
              startX = e.screenX;
              startY = e.screenY;
              e.preventDefault();
            });
            document.addEventListener('mousemove', function(e) {
              if (!isDragging || window.__crystkit_drag_disabled) return;
              var dx = e.screenX - startX;
              var dy = e.screenY - startY;
              if (window.__CRYSTKIT_IPC__ && window.__CRYSTKIT_IPC__.invoke) {
                window.__CRYSTKIT_IPC__.invoke('window:move_by', {x: dx, y: dy});
              }
              startX = e.screenX;
              startY = e.screenY;
            });
            document.addEventListener('mouseup', function() {
              isDragging = false;
            });
          })();
        JS
      end
    end
  end
end
