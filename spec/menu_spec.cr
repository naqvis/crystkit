require "./spec_helper"
require "../src/features/menu"

describe CrystKit::Features::MenuItem do
  it "creates with action" do
    fired = false
    item = CrystKit::Features::MenuItem.new(id: "test", label: "Test", action: -> { fired = true })
    item.action.try(&.call)
    fired.should be_true
  end
end

describe CrystKit::Features::Menu do
  it "adds an item with label and accelerator" do
    menu = CrystKit::Features::Menu.new("File")
    menu.add_item("Open", "Cmd+O") { }
    menu.items.size.should eq(1)
    item = menu.items.first.as(CrystKit::Features::MenuItem)
    item.label.should eq("Open")
    item.accelerator.should eq("Cmd+O")
  end

  it "adds an item with auto-generated id" do
    menu = CrystKit::Features::Menu.new("File")
    menu.add_item("Save As") { }
    item = menu.items.first.as(CrystKit::Features::MenuItem)
    item.id.should eq("save-as")
  end

  it "adds an item with explicit id" do
    menu = CrystKit::Features::Menu.new("File")
    menu.add_item("Save", id: "save-action") { }
    item = menu.items.first.as(CrystKit::Features::MenuItem)
    item.id.should eq("save-action")
  end

  it "adds separator" do
    menu = CrystKit::Features::Menu.new("File")
    menu.add_separator
    menu.items.size.should eq(1)
    menu.items.first.as(CrystKit::Features::MenuItem).id.should eq("__separator__")
  end

  it "adds submenu" do
    parent = CrystKit::Features::Menu.new("Parent")
    child = CrystKit::Features::Menu.new("Child")
    child.add_item("Action") { }
    parent.add_submenu(child)
    parent.items.size.should eq(1)
    parent.items.first.as(CrystKit::Features::Menu).label.should eq("Child")
  end

  it "add_menu is alias for add_submenu" do
    parent = CrystKit::Features::Menu.new("Parent")
    child = CrystKit::Features::Menu.new("Child")
    parent.add_menu(child)
    parent.items.size.should eq(1)
  end

  it "chains add_item calls" do
    menu = CrystKit::Features::Menu.new("Edit")
    menu.add_item("Cut", "Cmd+X") { }
      .add_separator
      .add_item("Copy", "Cmd+C") { }
      .add_item("Paste", "Cmd+V") { }
    menu.items.size.should eq(4)
  end

  it "creates a menu item via add_item with a block" do
    menu = CrystKit::Features::Menu.new("Test")
    menu.add_item("WithBlock", "Cmd+B") { }
    menu.items.size.should eq(1)
    menu.items.first.as(CrystKit::Features::MenuItem).label.should eq("WithBlock")
  end

  it "adds an item through the item builder alias" do
    menu = CrystKit::Features::Menu.new("File")

    menu.item("Quit", "Cmd+Q", id: "quit") { }

    menu.items.size.should eq(1)
    item = menu.items.first.as(CrystKit::Features::MenuItem)
    item.id.should eq("quit")
    item.label.should eq("Quit")
    item.accelerator.should eq("Cmd+Q")
  end
end

describe CrystKit::Features::MenuBar do
  it "adds a menu" do
    mb = CrystKit::Features::MenuBar.new
    file_menu = CrystKit::Features::Menu.new("File")
    mb.add(file_menu)
    mb.menus.size.should eq(1)
    mb.menus.first.label.should eq("File")
  end

  it "chains add calls" do
    mb = CrystKit::Features::MenuBar.new
    mb.add(CrystKit::Features::Menu.new("File"))
      .add(CrystKit::Features::Menu.new("Edit"))
      .add(CrystKit::Features::Menu.new("View"))
    mb.menus.size.should eq(3)
  end

  it "builds menus with a block" do
    menu_bar = CrystKit::Features::MenuBar.new

    menu_bar.menu("File") do |file|
      file.item("Quit", "Cmd+Q", id: "quit") { }
    end

    menu_bar.menus.size.should eq(1)
    menu_bar.menus.first.label.should eq("File")
    menu_bar.menus.first.items.first.as(CrystKit::Features::MenuItem).id.should eq("quit")
  end

  describe ".standard" do
    it "creates a standard application menu bar" do
      mb = CrystKit::Features::MenuBar.standard("TestApp")
      mb.menus.size.should eq(6)
    end

    it "includes an app menu" do
      mb = CrystKit::Features::MenuBar.standard("MyApp")
      mb.menus[0].label.should eq("MyApp")
    end

    it "includes File menu" do
      mb = CrystKit::Features::MenuBar.standard("App")
      mb.menus[1].label.should eq("File")
    end

    it "includes Edit menu" do
      mb = CrystKit::Features::MenuBar.standard("App")
      mb.menus[2].label.should eq("Edit")
    end

    it "includes View menu" do
      mb = CrystKit::Features::MenuBar.standard("App")
      mb.menus[3].label.should eq("View")
    end

    it "includes Window menu" do
      mb = CrystKit::Features::MenuBar.standard("App")
      mb.menus[4].label.should eq("Window")
    end

    it "includes Help menu" do
      mb = CrystKit::Features::MenuBar.standard("App")
      mb.menus[5].label.should eq("Help")
    end

    it "populates the app menu with About, Preferences, Quit" do
      mb = CrystKit::Features::MenuBar.standard("MyApp")
      app_menu = mb.menus[0]
      app_menu.items.size.should be >= 5
      labels = app_menu.items.map { |i| i.as(CrystKit::Features::MenuItem).label }
      labels.should contain("About MyApp")
      labels.should contain("Preferences...")
      labels.should contain("Quit MyApp")
    end

    it "populates the File menu with common items" do
      mb = CrystKit::Features::MenuBar.standard("App")
      file_menu = mb.menus[1]
      labels = file_menu.items.map { |i| i.as(CrystKit::Features::MenuItem).label }
      labels.should contain("New Window")
      labels.should contain("Open...")
      labels.should contain("Close")
    end
  end
end
