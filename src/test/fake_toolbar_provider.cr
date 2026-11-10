require "../features/toolbar"

module CrystKit
  module Test
    # Recording toolbar provider for specs.
    #
    # Captures every native call (`register`, `update_items`, `visible=`,
    # `cleanup`) so `Toolbar` sync/visibility logic can be asserted without a
    # native toolbar.
    class FakeToolbarProvider < Features::Toolbar::Provider
      getter registered : Features::Toolbar?
      getter items : Array(Features::ToolbarItem) = [] of Features::ToolbarItem
      property? visible : Bool = true
      getter? cleaned_up : Bool = false

      def register(native_handle : Void*, content_handle : Void*, toolbar : Features::Toolbar) : Nil
        @registered = toolbar
      end

      def update_items(items : Array(Features::ToolbarItem)) : Nil
        @items = items.dup
      end

      def visible=(visible : Bool) : Nil
        @visible = visible
      end

      def cleanup : Nil
        @cleaned_up = true
      end
    end
  end
end
