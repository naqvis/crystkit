require "./spec_helper"
require "../src/features/toolbar"
require "../src/features/watch_event"
require "../src/plugins/builtins/toolbar"
require "../src/features/asset_source"
require "../src/platform/icon_source"
require "virtualfs"

private class CapturingToolbarProvider < CrystKit::Features::Toolbar::Provider
  getter items = [] of CrystKit::Features::ToolbarItem
  getter visible_values = [] of Bool
  getter? cleaned_up = false

  def register(native_handle : Void*, content_handle : Void*, toolbar : CrystKit::Features::Toolbar) : Nil
    @items = toolbar.items
  end

  def update_items(items : Array(CrystKit::Features::ToolbarItem)) : Nil
    @items = items
  end

  def visible=(visible : Bool) : Nil
    @visible_values << visible
  end

  def cleanup : Nil
    @cleaned_up = true
  end
end

private def mem_with(files : Hash(String, String)) : VirtualFs::InMemory
  mem = VirtualFs::InMemory.new
  files.each { |p, c| mem.add_file(p, c.to_slice) }
  mem
end

module CrystKit::Features
  describe Toolbar do
    it "starts with empty items" do
      tb = Toolbar.new
      tb.items.should be_empty
    end

    it "starts visible" do
      tb = Toolbar.new
      tb.visible?.should be_true
    end

    it "adds an item" do
      tb = Toolbar.new
      tb.add_item("btn1", "Click Me") { }
      tb.items.size.should eq(1)
      item = tb.items.first
      item.id.should eq("btn1")
      item.label.should eq("Click Me")
      item.icon.should be_nil
      item.enabled?.should be_true
      item.checked?.should be_false
      item.action.should_not be_nil
    end

    it "adds an item with icon" do
      tb = Toolbar.new
      tb.add_item("btn1", "Click Me", "icon.png") { }
      item = tb.items.first
      item.icon_arg.should eq("icon.png")
      item.icon.not_nil!.name?.should be_true
      item.icon.not_nil!.name.should eq("icon.png")
    end

    it "resolves icons from VFS" do
      vfs = VirtualFs::Vfs.new
      vfs.mount(mem_with({"icons/save.svg" => "<svg/>"}), "/", priority: 0)
      source = CrystKit::Features::VfsAssetSource.new(vfs)
      tb = Toolbar.new(asset_source: source)
      tb.add_item("save", "Save", "icons/save.svg") { }
      item = tb.items.first
      item.icon_arg.should eq("icons/save.svg")
      item.icon.not_nil!.bytes?.should be_true
      String.new(item.icon.not_nil!.bytes.not_nil!).should eq("<svg/>")
      item.icon.not_nil!.key.should eq("icons/save.svg")
    end

    it "resolves theme-name icons" do
      tb = Toolbar.new
      tb.add_item("save", "Save", "edit-save") { }
      item = tb.items.first
      item.icon_arg.should eq("edit-save")
      item.icon.not_nil!.name?.should be_true
      item.icon.not_nil!.name.should eq("edit-save")
    end

    it "swaps an item icon via swap_item_icon and syncs to backend" do
      provider = CapturingToolbarProvider.new
      tb = Toolbar.new(provider: provider)
      tb.add_item("btn", "Btn") { }
      tb.swap_item_icon("btn", CrystKit::Platform::IconSource.name("new-icon"))
      item = tb.items.first
      item.icon.not_nil!.name?.should be_true
      item.icon.not_nil!.name.should eq("new-icon")
      provider.items.first.icon.not_nil!.name.should eq("new-icon")
    end

    it "swap_item_icon on unknown id does nothing" do
      tb = Toolbar.new
      tb.add_item("btn", "Btn") { }
      tb.swap_item_icon("nope", CrystKit::Platform::IconSource.name("x"))
      tb.items.size.should eq(1)
    end

    it "adds a separator" do
      tb = Toolbar.new
      tb.add_separator
      tb.items.size.should eq(1)
      item = tb.items.first
      item.id.should eq("__separator__")
      item.label.should eq("|")
    end

    it "adds multiple items" do
      tb = Toolbar.new
      tb.add_item("btn1", "One") { }
      tb.add_item("btn2", "Two") { }
      tb.items.size.should eq(2)
    end

    it "removes an item by id" do
      tb = Toolbar.new
      tb.add_item("btn1", "One") { }
      tb.add_item("btn2", "Two") { }
      tb.remove_item("btn1")
      tb.items.size.should eq(1)
      tb.items.first.id.should eq("btn2")
    end

    it "removing non-existent id does nothing" do
      tb = Toolbar.new
      tb.add_item("btn1", "One") { }
      tb.remove_item("nonexistent")
      tb.items.size.should eq(1)
    end

    it "clears all items" do
      tb = Toolbar.new
      tb.add_item("btn1", "One") { }
      tb.add_item("btn2", "Two") { }
      tb.clear
      tb.items.should be_empty
    end

    it "hides and shows" do
      tb = Toolbar.new
      tb.visible?.should be_true
      tb.hide
      tb.visible?.should be_false
      tb.show
      tb.visible?.should be_true
    end

    it "reads and writes style" do
      tb = Toolbar.new
      tb.style.should eq(ToolbarStyle::Default)
      tb.style = ToolbarStyle::Dark
      tb.style.should eq(ToolbarStyle::Dark)
    end

    it "reads and writes title" do
      tb = Toolbar.new
      tb.title.should eq("")
      tb.title = "Main Toolbar"
      tb.title.should eq("Main Toolbar")
    end

    it "add_item is chainable" do
      tb = Toolbar.new
      ret = tb.add_item("btn1", "One") { }
      ret.should be(tb)
    end

    it "items returns a dup" do
      tb = Toolbar.new
      tb.add_item("btn1", "One") { }
      items = tb.items
      items.clear
      tb.items.size.should eq(1)
    end

    it "item action is callable" do
      called = false
      tb = Toolbar.new
      tb.add_item("btn1", "Click") { called = true }
      action = tb.items.first.action
      action.should_not be_nil
      action.try(&.call)
      called.should be_true
    end

    it "full workflow" do
      tb = Toolbar.new
      tb.add_item("a", "A") { }
      tb.add_item("b", "B") { }
      tb.add_separator
      tb.hide
      tb.visible?.should be_false
      tb.remove_item("a")
      tb.items.size.should eq(2)
      tb.clear
      tb.items.should be_empty
      tb.show
      tb.visible?.should be_true
    end

    it "adds a toggle item" do
      tb = Toolbar.new
      tb.add_toggle("tog1", "Toggle Me", checked: true) { }
      tb.items.size.should eq(1)
      item = tb.items.first
      item.id.should eq("tog1")
      item.label.should eq("Toggle Me")
      item.item_type.should eq(ToolbarItemType::Toggle)
      item.checked?.should be_true
      item.action.should_not be_nil
    end

    it "adds a dropdown item" do
      tb = Toolbar.new
      tb.add_dropdown("dd1", "Pick One", options: ["A", "B", "C"], selected_index: 1) { }
      tb.items.size.should eq(1)
      item = tb.items.first
      item.id.should eq("dd1")
      item.label.should eq("Pick One")
      item.item_type.should eq(ToolbarItemType::Dropdown)
      item.options.should eq(["A", "B", "C"])
      item.selected_index.should eq(1)
      item.action.should_not be_nil
    end

    it "toggle item defaults to unchecked" do
      tb = Toolbar.new
      tb.add_toggle("tog1", "Toggle") { }
      tb.items.first.checked?.should be_false
    end

    it "dropdown item defaults to empty options" do
      tb = Toolbar.new
      tb.add_dropdown("dd1", "Dropdown") { }
      tb.items.first.options.should be_empty
      tb.items.first.selected_index.should eq(0)
    end

    it "add_toggle is chainable" do
      tb = Toolbar.new
      ret = tb.add_toggle("tog1", "Toggle") { }
      ret.should be(tb)
    end

    it "add_dropdown is chainable" do
      tb = Toolbar.new
      ret = tb.add_dropdown("dd1", "Dropdown") { }
      ret.should be(tb)
    end

    it "toggle item action is callable" do
      called = false
      tb = Toolbar.new
      tb.add_toggle("tog1", "Toggle") { called = true }
      action = tb.items.first.action
      action.should_not be_nil
      action.try(&.call)
      called.should be_true
    end

    it "dropdown item action is callable" do
      called = false
      tb = Toolbar.new
      tb.add_dropdown("dd1", "Dropdown", options: ["A", "B"]) { called = true }
      action = tb.items.first.action
      action.should_not be_nil
      action.try(&.call)
      called.should be_true
    end
  end

  describe ToolbarItemType do
    it "has Button as default" do
      ToolbarItem.new(id: "a", label: "A").item_type.should eq(ToolbarItemType::Button)
    end

    it "parses known types" do
      ToolbarItemType.parse?("button").should eq(ToolbarItemType::Button)
      ToolbarItemType.parse?("toggle").should eq(ToolbarItemType::Toggle)
      ToolbarItemType.parse?("dropdown").should eq(ToolbarItemType::Dropdown)
    end

    it "returns nil for unknown type" do
      ToolbarItemType.parse?("unknown").should be_nil
    end
  end

  describe ToolbarStyle do
    it "parses known styles" do
      ToolbarStyle.parse?("default").should eq(ToolbarStyle::Default)
      ToolbarStyle.parse?("dark").should eq(ToolbarStyle::Dark)
      ToolbarStyle.parse?("light").should eq(ToolbarStyle::Light)
      ToolbarStyle.parse?("transparent").should eq(ToolbarStyle::Transparent)
    end

    it "returns nil for unknown style" do
      ToolbarStyle.parse?("unknown").should be_nil
    end
  end
end

module CrystKit::Plugins
  describe Toolbar do
    it "returns identifier" do
      plugin = Toolbar.new
      plugin.identifier.should eq("toolbar")
    end

    it "returns metadata with toolbar commands" do
      plugin = Toolbar.new
      meta = plugin.metadata
      meta.id.should eq("toolbar")
      meta.commands.should contain("toolbar.add_item")
      meta.commands.should contain("toolbar.remove_item")
      meta.commands.should contain("toolbar.clear")
      meta.commands.should contain("toolbar.show")
      meta.commands.should contain("toolbar.hide")
      meta.commands.should contain("toolbar.visible?")
      meta.commands.should contain("toolbar.set_style")
      meta.commands.should contain("toolbar.set_title")
      meta.commands.should contain("toolbar.items")
      meta.events.should contain("toolbar.click")
    end

    it "emits toolbar.click when an IPC-created item action runs" do
      provider = CapturingToolbarProvider.new
      platform = CrystKit::Platform::Services.new
      app = CrystKit::App.new(
        CrystKit::AppConfig.new(
          identifier: "test.toolbar.#{Random.rand(100_000)}",
          storage_dir: Path[File.tempname("toolbar_plugin_spec")]
        ),
        platform
      )
      received = [] of String
      app.on("toolbar.click") { |payload| received << payload["item_id"].as_s }
      app.plugin(Toolbar.new(provider))

      app.router.invoke_command(
        "toolbar.add_item",
        JSON.parse(%(["save","Save",null]))
      )

      provider.items.first.action.try(&.call)
      received.should eq(["save"])
    end

    it "attaches its toolbar only to the first window" do
      provider = CapturingToolbarProvider.new
      platform = CrystKit::Platform::Services.new(
        window: CrystKit::Test::FakeWindowBackend.new
      )
      app = CrystKit::App.new(
        CrystKit::AppConfig.new(
          identifier: "test.toolbar.owner.#{Random.rand(100_000)}",
          storage_dir: Path[File.tempname("toolbar_owner_spec")]
        ),
        platform
      )
      plugin = Toolbar.new(provider)
      app.plugin(plugin)

      owner = app.window(label: "owner")
      child = app.window(label: "child")

      owner.toolbar.should be(plugin.toolbar)
      child.toolbar.should be_nil

      child.destroy
      provider.cleaned_up?.should be_false
      owner.toolbar.should be(plugin.toolbar)

      owner.destroy
      provider.cleaned_up?.should be_true
    end
  end
end
