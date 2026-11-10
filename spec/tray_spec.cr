require "./spec_helper"
require "../src/features/tray"

describe CrystKit::Features::TrayMenuItem do
  it "fires click handler" do
    clicked = false
    item = CrystKit::Features::TrayMenuItem.new("test", "Test")
    item.on_click { |_event| clicked = true }
    item.trigger_click
    clicked.should be_true
  end

  it "passes event to click handler" do
    received_id = ""
    item = CrystKit::Features::TrayMenuItem.new("my-item", "My Item")
    item.on_click { |event| received_id = event.item_id }
    item.trigger_click
    received_id.should eq("my-item")
  end
end

describe CrystKit::Features::TrayMenu do
  it "starts empty" do
    menu = CrystKit::Features::TrayMenu.new
    menu.items.should be_empty
  end

  it "adds an item" do
    menu = CrystKit::Features::TrayMenu.new
    menu.add_item(CrystKit::Features::TrayMenuItem.new("a", "A"))
    menu.items.size.should eq(1)
    menu.items.first.id.should eq("a")
  end

  it "adds a menu item" do
    menu = CrystKit::Features::TrayMenu.new
    item = CrystKit::Features::TrayMenuItem.new("b", "B")
    menu.add_item(item)
    menu.items.size.should eq(1)
    menu.items.first.id.should eq("b")
  end

  it "adds separator" do
    menu = CrystKit::Features::TrayMenu.new
    menu.add_separator
    menu.items.size.should eq(1)
    menu.items.first.type.should eq(CrystKit::Features::TrayMenuItemType::Separator)
  end

  it "adds multiple items and preserves order" do
    menu = CrystKit::Features::TrayMenu.new
    menu.add_item(CrystKit::Features::TrayMenuItem.new("first", "First"))
    menu.add_separator
    menu.add_item(CrystKit::Features::TrayMenuItem.new("second", "Second"))
    menu.items.size.should eq(3)
    menu.items[0].id.should eq("first")
    menu.items[1].type.should eq(CrystKit::Features::TrayMenuItemType::Separator)
    menu.items[2].id.should eq("second")
  end

  it "supports nested submenus" do
    parent = CrystKit::Features::TrayMenu.new
    child = CrystKit::Features::TrayMenu.new
    child.add_item(CrystKit::Features::TrayMenuItem.new("nested", "Nested"))
    sub_item = CrystKit::Features::TrayMenuItem.new("sub", "Sub")
    sub_item.submenu = child
    parent.add_item(sub_item)
    parent.items.size.should eq(1)
    parent.items.first.as(CrystKit::Features::TrayMenuItem).submenu.should be(child)
  end

  it "can have items replaced by creating a new menu" do
    menu = CrystKit::Features::TrayMenu.new
    menu.add_item(CrystKit::Features::TrayMenuItem.new("a", "A"))
    menu.items.size.should eq(1)
    new_menu = CrystKit::Features::TrayMenu.new
    new_menu.items.should be_empty
  end

  it "returns a copy of items" do
    menu = CrystKit::Features::TrayMenu.new
    menu.add_item(CrystKit::Features::TrayMenuItem.new("a", "A"))
    items_copy = menu.items
    items_copy << CrystKit::Features::TrayMenuItem.new("b", "B")
    menu.items.size.should eq(1)
  end
end

describe CrystKit::Features::MouseButton do
  it "includes Left" do
    CrystKit::Features::MouseButton::Left.to_s.should eq("Left")
  end

  it "includes Right" do
    CrystKit::Features::MouseButton::Right.to_s.should eq("Right")
  end

  it "includes Middle" do
    CrystKit::Features::MouseButton::Middle.to_s.should eq("Middle")
  end
end

require "../src/features/asset_resolution"
require "../src/features/asset_source"
require "../src/platform/icon_source"
require "virtualfs"

private class RecordingTrayProvider < CrystKit::Features::SystemTray::Provider
  getter create_calls = [] of Tuple(String, CrystKit::Platform::IconSource?, String?)
  getter update_calls = [] of CrystKit::Platform::IconSource
  getter? destroyed = false

  def on_click(&block : Int32 ->) : Nil; end

  def set_menu(items, callbacks) : Nil; end

  def tooltip=(text : String) : Nil; end

  def destroy : Nil
    @destroyed = true
  end

  def create(app_id, icon, tooltip) : Nil
    @create_calls << {app_id, icon, tooltip}
  end

  def update_icon(icon) : Nil
    @update_calls << icon
  end
end

private def mem_with(files : Hash(String, String)) : VirtualFs::InMemory
  mem = VirtualFs::InMemory.new
  files.each { |p, c| mem.add_file(p, c.to_slice) }
  mem
end

describe CrystKit::Features::SystemTray do
  describe "icon resolution" do
    it "passes IconSource.bytes to backend for a VFS path" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icons/tray.png" => "PNGBYTES"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)
      provider = RecordingTrayProvider.new
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("tray")
      tray = CrystKit::Features::SystemTray.new(caps, provider: provider, asset_source: source)

      tray.create(Path.new("icons/tray.png"), tooltip: "t")
      provider.create_calls.size.should eq(1)
      _, icon, _ = provider.create_calls.first
      icon.should_not be_nil
      icon.not_nil!.bytes?.should be_true
      String.new(icon.not_nil!.bytes.not_nil!).should eq("PNGBYTES")
      icon.not_nil!.key.should eq("icons/tray.png")
    end

    it "passes IconSource.name to backend for a String" do
      provider = RecordingTrayProvider.new
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("tray")
      tray = CrystKit::Features::SystemTray.new(caps, provider: provider)

      tray.create("edit-delete", tooltip: "t")
      _, icon, _ = provider.create_calls.first
      icon.not_nil!.name?.should be_true
      icon.not_nil!.name.should eq("edit-delete")
    end

    it "raises ICON_NOT_FOUND when the VFS misses and no disk fallback" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"other.png" => "x"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)
      provider = RecordingTrayProvider.new
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("tray")
      tray = CrystKit::Features::SystemTray.new(caps, provider: provider, asset_source: source)

      error = expect_raises(CrystKit::Core::Error) do
        tray.create(Path.new("icons/missing.png"))
      end
      error.code.should eq("ICON_NOT_FOUND")
    end

    it "raises ASSET_FETCHER_REQUIRED when a URI is given but no fetcher" do
      provider = RecordingTrayProvider.new
      caps = CrystKit::Security::CapabilitySystem.new
      caps.grant("tray")
      tray = CrystKit::Features::SystemTray.new(caps, provider: provider)

      error = expect_raises(CrystKit::Core::Error) do
        tray.create(URI.parse("http://localhost/x.png"))
      end
      error.code.should eq("ASSET_FETCHER_REQUIRED")
    end
  end
end
