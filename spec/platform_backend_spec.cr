require "spec"
require "../src/features/safe_storage"
require "../src/features/hardware"
require "../src/features/drag_source"
require "../src/features/printing"
require "../src/features/system_info"
require "../src/features/positioning"
require "../src/features/devtools"
require "../src/features/menu"
require "../src/features/window_effects"
require "../src/features/custom_protocol"
require "../src/features/file_watcher"

private class FakeMenuProvider < CrystKit::Features::MenuBar::Provider
  getter? installed = false

  def requires_running_event_loop? : Bool
    false
  end

  def install(menu_bar, window_ptr : Void*?) : Nil
    @installed = true
  end
end

private class FakeWindowEffectsProvider < CrystKit::Features::WindowEffectsProvider
  getter? applied = false

  def apply(window_ptr : Void*, config) : Nil
    @applied = true
  end
end

private class FakePositioningProvider < CrystKit::Features::PositioningProvider
  def screen_list : Array(CrystKit::Features::ScreenInfo)
    bounds = CrystKit::Features::Rectangle.new(0, 0, 800, 600)
    [CrystKit::Features::ScreenInfo.new(bounds, bounds)]
  end

  def cursor_position : CrystKit::Features::Point
    CrystKit::Features::Point.new(10, 20)
  end

  def start_screen_monitor(callback : ->) : Nil
  end
end

describe CrystKit::Features::MenuBar do
  it "delegates installation through an injected provider" do
    provider = FakeMenuProvider.new
    menu = CrystKit::Features::MenuBar.new(provider)

    menu.install

    provider.installed?.should be_true
  end
end

describe CrystKit::Features::WindowEffects do
  it "delegates native effects through an injected platform backend" do
    provider = FakeWindowEffectsProvider.new
    effects = CrystKit::Features::WindowEffects.new(provider: provider)
    effects.config.mica = true

    effects.apply(Pointer(Void).new(1_u64))

    provider.applied?.should be_true
  end

  it "keeps menu and window-effects features independent from concrete OS modules" do
    source = File.read(Path[__DIR__] / "../src/features/menu.cr") +
             File.read(Path[__DIR__] / "../src/features/window_effects.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end

describe CrystKit::Features::WindowPositioner do
  it "delegates screen and cursor queries through an injected platform backend" do
    positioner = CrystKit::Features::WindowPositioner.new(FakePositioningProvider.new)

    positioner.display_count.should eq(1)
    positioner.cursor.should eq(CrystKit::Features::Point.new(10, 20))
  end

  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/positioning.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end

describe CrystKit::Features::DevTools do
  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/devtools.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
  end
end

describe CrystKit::Features::CustomProtocol do
  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/custom_protocol.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end

private class FakePrintingBackend < CrystKit::Platform::PrintingBackend
  getter? printed = false

  def print(window : Void*, options) : Bool
    @printed = true
  end

  def print_to_pdf(window : Void*, output : String, options) : Bool
    true
  end

  def list_printers : Array(String)
    ["Test Printer"]
  end

  def show_dialog(window : Void*, options) : Bool
    true
  end
end

describe CrystKit::Features::SystemInfo do
  it "uses the standalone host information provider" do
    info = CrystKit::Features::SystemInfo.new
    info.os_info.name.should_not be_empty
    info.cpu_info.cores.should be > 0
    info.home_directory.should_not be_empty
  end

  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/system_info.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end

describe CrystKit::Features::Printer do
  it "delegates printing through an injected platform backend" do
    backend = FakePrintingBackend.new
    printer = CrystKit::Features::Printer.new(backend: backend)
    window = Pointer(Void).new(1_u64)

    printer.print(window).should be_true
    printer.list_printers.should eq(["Test Printer"])
    backend.printed?.should be_true
  end

  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/printing.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end

private class FakeHardwareProvider < CrystKit::Features::HardwareAPI::Provider
  def available?(type : CrystKit::Features::HardwareAPIType) : Bool
    type.bluetooth?
  end

  def enumerate(type : CrystKit::Features::HardwareAPIType) : Array(CrystKit::Features::HardwareDeviceInfo)
    [CrystKit::Features::HardwareDeviceInfo.new("device-1", "Test Device", type)]
  end
end

describe CrystKit::Features::SafeStorage do
  it "keeps platform backend selection out of its public constructor" do
    CrystKit::Features::SafeStorage.new.should be_a(CrystKit::Features::SafeStorage)
    source = File.read(Path[__DIR__] / "../src/features/safe_storage.cr")
    source.should_not contain("def initialize(@backend")
    source.should contain("::SafeStorage.open(service)")
  end

  it "contains no concrete OS dispatch or insecure file fallback" do
    source = File.read(Path[__DIR__] / "../src/features/safe_storage.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
    source.should_not contain("fallback")
  end
end

describe CrystKit::Features::HardwareAPI do
  it "delegates availability and enumeration through a provider" do
    capabilities = CrystKit::Security::CapabilitySystem.new
    capabilities.grant("hardware:list")
    api = CrystKit::Features::HardwareAPI.new(capabilities, FakeHardwareProvider.new)

    api.available?(CrystKit::Features::HardwareAPIType::Bluetooth).should be_true
    api.enumerate(CrystKit::Features::HardwareAPIType::Bluetooth).map(&.id).should eq(["device-1"])
  end

  it "contains no concrete OS dispatch" do
    source = File.read(Path[__DIR__] / "../src/features/hardware.cr")

    source.should_not contain("Platform::MacOS")
    source.should_not contain("Platform::Linux")
    source.should_not contain("Platform::Windows")
    source.should_not contain("{% if flag?")
  end
end
