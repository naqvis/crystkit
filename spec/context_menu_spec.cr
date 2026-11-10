require "./spec_helper"
require "../src/features/context_menu"

class FakeContextMenuProvider < CrystKit::Features::ContextMenu::Provider
  property last_items : Array(CrystKit::Features::ContextMenu::Item)?
  property last_x : Int32?
  property last_y : Int32?
  property return_item_id : String?
  property raise_on_show : Exception?
  property? return_available : Bool = true

  def available? : Bool
    @return_available
  end

  def show(items, x : Int32, y : Int32, window_ptr : Void*) : String?
    @last_items = items
    @last_x = x
    @last_y = y
    if ex = @raise_on_show
      raise ex
    end
    @return_item_id
  end
end

describe CrystKit::Features::ContextMenu do
  describe "capability gating" do
    it "raises SecurityError when context_menu:custom is not granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      expect_raises(CrystKit::Core::SecurityError, /context_menu:custom/) do
        cm.on_default(&.add("Test"))
      end
    end
    it "proceeds when capability is granted" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      cm.on_default(&.add("Test"))
    end
  end
  describe "handler routing" do
    it "calls on_link handler when linkUrl is present" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      called = false
      cm.on_link { |b| called = true; b.add("Open Link", id: "open-link") }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(link_url: "https://example.com"), Pointer(Void).null)
      called.should be_true
    end
    it "calls on_image handler when imageSrc is present" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      called = false
      cm.on_image { |b| called = true; b.add("Save Image", id: "save-image") }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(image_src: "https://example.com/img.png"), Pointer(Void).null)
      called.should be_true
    end
    it "calls on_editable handler when isEditable is true" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      called = false
      cm.on_editable { |b| called = true; b.add("Paste", id: "paste") }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(is_editable: true), Pointer(Void).null)
      called.should be_true
    end
    it "calls on_text_selection handler when selection is non-empty" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      called = false
      cm.on_text_selection { |b| called = true; b.add("Search", id: "search") }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(selection: "hello world"), Pointer(Void).null)
      called.should be_true
    end
    it "calls on_default when no specific handler matches" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      called = false
      cm.on_default { |b| called = true; b.add("Action", id: "action") }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new, Pointer(Void).null)
      called.should be_true
    end
    it "prefers higher-priority handler over lower" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      which = ""
      cm.on_default { |_b| which = "default" }
      cm.on_link { |_b| which = "link" }
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(link_url: "https://x.com"), Pointer(Void).null)
      which.should eq("link")
    end
  end
  describe "context menu builder" do
    it "adds items to the menu" do
      ctx = CrystKit::Features::ContextMenu::ContextData.new
      builder = CrystKit::Features::ContextMenuBuilder.new(ctx)
      builder.add("Item 1", id: "item-1")
      builder.add("Item 2", id: "item-2")
      builder.items.size.should eq(2)
      builder.items[0].id.should eq("item-1")
      builder.items[1].label.should eq("Item 2")
    end
    it "adds separators" do
      ctx = CrystKit::Features::ContextMenu::ContextData.new
      builder = CrystKit::Features::ContextMenuBuilder.new(ctx)
      builder.add_separator
      builder.items.size.should eq(1)
      builder.items[0].type.should eq(CrystKit::Features::ContextMenu::Item::Type::Separator)
    end
    it "adds submenus" do
      ctx = CrystKit::Features::ContextMenu::ContextData.new
      builder = CrystKit::Features::ContextMenuBuilder.new(ctx)
      builder.add_submenu("Sub") do |sub|
        sub.add("Nested", id: "nested")
      end
      builder.items.size.should eq(1)
      sub = builder.items[0].submenu
      sub.should_not be_nil
      sub.try(&.size).should eq(1)
      sub.try(&.[0].id).should eq("nested")
    end
    it "adds checkbox items" do
      ctx = CrystKit::Features::ContextMenu::ContextData.new
      builder = CrystKit::Features::ContextMenuBuilder.new(ctx)
      builder.add_checkbox("Enable", "enable", checked: true)
      builder.items.size.should eq(1)
      builder.items[0].checked?.should be_true
      builder.items[0].type.should eq(CrystKit::Features::ContextMenu::Item::Type::Checkbox)
    end
  end
  describe "provider interaction" do
    it "passes cursor coordinates to the backend" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      cm.on_default(&.add("Test", id: "t"))
      cm.show(CrystKit::Features::ContextMenu::ContextData.new(x: 100, y: 200), Pointer(Void).null)
      backend.last_x.should eq(100)
      backend.last_y.should eq(200)
    end
    it "returns the item_id from the backend" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      backend.return_item_id = "my-item"
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      cm.on_default(&.add("Test", id: "my-item"))
      result = cm.show(CrystKit::Features::ContextMenu::ContextData.new, Pointer(Void).null)
      result.should eq("my-item")
    end
    it "returns nil when no items are added" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      result = cm.show(CrystKit::Features::ContextMenu::ContextData.new, Pointer(Void).null)
      result.should be_nil
    end
    it "propagates backend exceptions" do
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("context_menu:custom")
      backend = FakeContextMenuProvider.new
      backend.raise_on_show = Exception.new("backend error")
      cm = CrystKit::Features::ContextMenu.new(backend, caps)
      cm.on_default(&.add("Test", id: "t"))
      expect_raises(Exception, "backend error") do
        cm.show(CrystKit::Features::ContextMenu::ContextData.new, Pointer(Void).null)
      end
    end
    it "delegates available? to the backend" do
      backend = FakeContextMenuProvider.new
      cm = CrystKit::Features::ContextMenu.new(backend)
      backend.return_available = false
      cm.available?.should be_false
      backend.return_available = true
      cm.available?.should be_true
    end
  end
end
