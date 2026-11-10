require "./spec_helper"
require "../src/features/hardware"

private class HardwareMonitorProvider < CrystKit::Features::HardwareAPI::Provider
  getter monitored_types = [] of CrystKit::Features::HardwareAPIType
  getter interval = 0.seconds
  getter? stopped = false
  @handler : Proc(String, CrystKit::Features::HardwareDeviceInfo, Nil)?

  def available?(type : CrystKit::Features::HardwareAPIType) : Bool
    true
  end

  def enumerate(type : CrystKit::Features::HardwareAPIType) : Array(CrystKit::Features::HardwareDeviceInfo)
    [] of CrystKit::Features::HardwareDeviceInfo
  end

  def start_monitor(
    types : Array(CrystKit::Features::HardwareAPIType),
    interval : Time::Span,
    handler : Proc(String, CrystKit::Features::HardwareDeviceInfo, Nil),
  ) : Nil
    @monitored_types = types
    @interval = interval
    @handler = handler
  end

  def stop_monitor : Nil
    @stopped = true
  end

  def emit(type : String, device : CrystKit::Features::HardwareDeviceInfo) : Nil
    @handler.not_nil!.call(type, device)
  end
end

describe CrystKit::Features::HardwareAPIType do
  it "parses from string" do
    t = CrystKit::Features::HardwareAPIType.parse?("Bluetooth")
    t.should eq(CrystKit::Features::HardwareAPIType::Bluetooth)
  end
end
describe CrystKit::Features::HardwareDeviceInfo do
  it "serializes to JSON" do
    device = CrystKit::Features::HardwareDeviceInfo.new(
      id: "json-test", name: "JSON", api_type: CrystKit::Features::HardwareAPIType::Serial,
    )
    json = device.to_json
    json.should contain("json-test")
    json.should contain("serial")
  end
end
describe CrystKit::Features::HardwareAPI do
  it "checks platform availability" do
    api = CrystKit::Features::HardwareAPI.new
    api.available?(CrystKit::Features::HardwareAPIType::Serial).should be_true
  end
  it "registers and lists devices" do
    api = CrystKit::Features::HardwareAPI.new
    device = CrystKit::Features::HardwareDeviceInfo.new(
      id: "bt-1", name: "Headset", api_type: CrystKit::Features::HardwareAPIType::Bluetooth,
    )
    api.register_device(device)
    devices = api.list_devices(CrystKit::Features::HardwareAPIType::Bluetooth)
    devices.size.should eq(1)
    devices.first.name.should eq("Headset")
  end
  it "lists only connected devices" do
    api = CrystKit::Features::HardwareAPI.new
    d1 = CrystKit::Features::HardwareDeviceInfo.new(id: "d1", name: "D1", api_type: CrystKit::Features::HardwareAPIType::USB)
    d2 = CrystKit::Features::HardwareDeviceInfo.new(id: "d2", name: "D2", api_type: CrystKit::Features::HardwareAPIType::USB)
    api.register_device(d1)
    api.register_device(d2)
    api.unregister_device("d2")
    devices = api.list_devices(CrystKit::Features::HardwareAPIType::USB)
    devices.size.should eq(1)
    devices.first.id.should eq("d1")
  end
  it "separates device types" do
    api = CrystKit::Features::HardwareAPI.new
    bt = CrystKit::Features::HardwareDeviceInfo.new(id: "bt", name: "BT", api_type: CrystKit::Features::HardwareAPIType::Bluetooth)
    usb = CrystKit::Features::HardwareDeviceInfo.new(id: "usb", name: "USB", api_type: CrystKit::Features::HardwareAPIType::USB)
    api.register_device(bt)
    api.register_device(usb)
    api.list_devices(CrystKit::Features::HardwareAPIType::Bluetooth).size.should eq(1)
    api.list_devices(CrystKit::Features::HardwareAPIType::USB).size.should eq(1)
    api.list_devices(CrystKit::Features::HardwareAPIType::Serial).size.should eq(0)
  end
  it "requires hardware:list capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    api = CrystKit::Features::HardwareAPI.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /hardware:list/) do
      api.list_devices(CrystKit::Features::HardwareAPIType::Bluetooth)
    end
  end
  it "requires hardware:manage capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    api = CrystKit::Features::HardwareAPI.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /hardware:manage/) do
      api.forget_device("test-1")
    end
  end
  it "runs connect handlers" do
    api = CrystKit::Features::HardwareAPI.new
    handled = false
    api.on_device_connected { |_| handled = true }
    device = CrystKit::Features::HardwareDeviceInfo.new(id: "h", name: "H", api_type: CrystKit::Features::HardwareAPIType::Serial)
    api.register_device(device)
    handled.should be_true
  end
  it "runs disconnect handlers" do
    api = CrystKit::Features::HardwareAPI.new
    handled = false
    api.on_device_disconnected { |id| handled = true if id == "disc" }
    device = CrystKit::Features::HardwareDeviceInfo.new(id: "disc", name: "D", api_type: CrystKit::Features::HardwareAPIType::Serial)
    api.register_device(device)
    api.unregister_device("disc")
    handled.should be_true
  end
  it "routes monitor events through the device registry" do
    provider = HardwareMonitorProvider.new
    api = CrystKit::Features::HardwareAPI.new(provider: provider)
    connected = [] of String
    disconnected = [] of String
    api.on_device_connected { |device| connected << device.id }
    api.on_device_disconnected { |id| disconnected << id }

    api.start_monitoring([CrystKit::Features::HardwareAPIType::USB], 250.milliseconds)
    provider.monitored_types.should eq([CrystKit::Features::HardwareAPIType::USB])
    provider.interval.should eq(250.milliseconds)

    device = CrystKit::Features::HardwareDeviceInfo.new(
      id: "monitor-usb",
      name: "Monitored USB",
      api_type: CrystKit::Features::HardwareAPIType::USB,
    )
    provider.emit("connected", device)
    api.list_devices(CrystKit::Features::HardwareAPIType::USB).map(&.id).should eq(["monitor-usb"])
    connected.should eq(["monitor-usb"])

    provider.emit("disconnected", device)
    api.list_devices(CrystKit::Features::HardwareAPIType::USB).should be_empty
    disconnected.should eq(["monitor-usb"])

    api.stop_monitoring
    provider.stopped?.should be_true
  end
  it "allows handlers to re-enter the registry" do
    api = CrystKit::Features::HardwareAPI.new
    connected_count = 0
    disconnected_count = 0
    api.on_device_connected { |_| connected_count = api.all_devices.size }
    api.on_device_disconnected { |_| disconnected_count = api.all_devices.size }
    device = CrystKit::Features::HardwareDeviceInfo.new(id: "reentrant", name: "Device", api_type: CrystKit::Features::HardwareAPIType::USB)

    api.register_device(device)
    api.unregister_device(device.id)

    connected_count.should eq(1)
    disconnected_count.should eq(0)
  end
  it "isolation between different APIs" do
    api = CrystKit::Features::HardwareAPI.new
    api1 = CrystKit::Features::HardwareAPI.new
    d = CrystKit::Features::HardwareDeviceInfo.new(id: "iso", name: "Iso", api_type: CrystKit::Features::HardwareAPIType::Bluetooth)
    api.register_device(d)
    api1.list_devices(CrystKit::Features::HardwareAPIType::Bluetooth).size.should eq(0)
  end
  it "forget_device removes from all devices" do
    api = CrystKit::Features::HardwareAPI.new(capabilities: nil)
    d = CrystKit::Features::HardwareDeviceInfo.new(id: "rem", name: "Rem", api_type: CrystKit::Features::HardwareAPIType::USB)
    api.register_device(d)
    api.all_devices.size.should eq(1)
    api.forget_device("rem")
    api.all_devices.size.should eq(0)
  end
end
