require "./spec_helper"
require "../src/features/shortcuts"

describe CrystKit::Features::Modifier do
  it "includes Ctrl" do
    CrystKit::Features::Modifier::Ctrl.to_s.should eq("Ctrl")
  end

  it "includes Alt" do
    CrystKit::Features::Modifier::Alt.to_s.should eq("Alt")
  end

  it "includes Shift" do
    CrystKit::Features::Modifier::Shift.to_s.should eq("Shift")
  end

  it "includes Meta" do
    CrystKit::Features::Modifier::Meta.to_s.should eq("Meta")
  end
end

describe CrystKit::Features::GlobalShortcuts do
  describe "#register" do
    it "registers a simple shortcut" do
      gs = CrystKit::Features::GlobalShortcuts.new
      triggered = false
      gs.register("Ctrl+Shift+A") { triggered = true }
      gs.registered.should contain("Ctrl+Shift+A")
    end

    it "normalizes accelerator strings" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Meta+Shift+S") { }
      gs.registered.should contain("Meta+Shift+S")
    end

    it "raises on duplicate registration" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Ctrl+Q") { }
      expect_raises(CrystKit::Core::Error, /already registered/) do
        gs.register("Ctrl+Q") { }
      end
    end

    it "handles alt modifier" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Alt+Space") { }
      gs.registered.should contain("Alt+Space")
    end

    it "handles meta as cmd" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Cmd+Z") { }
      gs.registered.should contain("Meta+Z")
    end

    it "raises on unknown modifier" do
      gs = CrystKit::Features::GlobalShortcuts.new
      expect_raises(CrystKit::Core::Error, /Unknown modifier/) do
        gs.register("Super+X") { }
      end
    end

    it "raises on empty accelerator" do
      gs = CrystKit::Features::GlobalShortcuts.new
      expect_raises(CrystKit::Core::Error, /Unknown key/) do
        gs.register("") { }
      end
    end
  end

  describe "#unregister" do
    it "removes a shortcut" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Ctrl+Shift+P") { }
      gs.registered.size.should eq(1)
      gs.unregister("Ctrl+Shift+P")
      gs.registered.should be_empty
    end

    it "does not raise when unregistering non-existent" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.unregister("Alt+Z")
      gs.registered.should be_empty
    end
  end

  describe "#unregister_all" do
    it "removes all shortcuts" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Ctrl+A") { }
      gs.register("Ctrl+B") { }
      gs.register("Ctrl+C") { }
      gs.unregister_all
      gs.registered.should be_empty
    end
  end

  describe "#listening?" do
    it "starts as not listening" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.listening?.should be_false
    end
  end

  describe "#registered" do
    it "returns all registered accelerators" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.register("Ctrl+A") { }
      gs.register("Ctrl+B") { }
      registered = gs.registered
      registered.size.should eq(2)
      registered.should contain("Ctrl+A")
      registered.should contain("Ctrl+B")
    end
  end

  describe "#trigger" do
    it "fires the registered handler" do
      gs = CrystKit::Features::GlobalShortcuts.new
      triggered = false
      gs.register("Ctrl+Shift+T") { triggered = true }
      gs.trigger("Ctrl+Shift+T")
      triggered.should be_true
    end

    it "does nothing for unregistered shortcut" do
      gs = CrystKit::Features::GlobalShortcuts.new
      gs.trigger("Alt+Z")
    end
  end

  describe "#parse_accelerator" do
    it "parses single key" do
      gs = CrystKit::Features::GlobalShortcuts.new
      shortcut = gs.parse_accelerator("A")
      shortcut.modifiers.should be_empty
      shortcut.key.should eq(CrystKit::Features::Key::A)
    end

    it "parses Ctrl+Shift+A" do
      gs = CrystKit::Features::GlobalShortcuts.new
      shortcut = gs.parse_accelerator("Ctrl+Shift+A")
      shortcut.modifiers.should eq([CrystKit::Features::Modifier::Ctrl, CrystKit::Features::Modifier::Shift])
      shortcut.key.should eq(CrystKit::Features::Key::A)
    end

    it "parses Meta+Shift+S" do
      gs = CrystKit::Features::GlobalShortcuts.new
      shortcut = gs.parse_accelerator("Meta+Shift+S")
      shortcut.modifiers.should eq([CrystKit::Features::Modifier::Meta, CrystKit::Features::Modifier::Shift])
      shortcut.key.should eq(CrystKit::Features::Key::S)
    end

    it "parses function keys" do
      gs = CrystKit::Features::GlobalShortcuts.new
      shortcut = gs.parse_accelerator("F5")
      shortcut.key.should eq(CrystKit::Features::Key::F5)
    end

    it "parses space key" do
      gs = CrystKit::Features::GlobalShortcuts.new
      shortcut = gs.parse_accelerator("Alt+Space")
      shortcut.key.should eq(CrystKit::Features::Key::Space)
    end

    it "raises on invalid key" do
      gs = CrystKit::Features::GlobalShortcuts.new
      expect_raises(CrystKit::Core::Error) do
        gs.parse_accelerator("Ctrl+InvalidKey123")
      end
    end
  end
end
