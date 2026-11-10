require "./spec_helper"
require "../src/features/power_monitor"

alias PowerBatteryInfo = CrystKit::Features::PowerMonitor::BatteryInfo

describe CrystKit::Features::PowerMonitor do
  it "returns the provider's battery snapshot" do
    info = PowerBatteryInfo.new(charging: false, level: 0.42, external_power: false)
    monitor = CrystKit::Features::PowerMonitor.new(CrystKit::Test::FakePowerProvider.new(info))

    monitor.battery_info.should eq(info)
    monitor.on_battery?.should be_true
  end

  it "reports no battery when the provider has no snapshot" do
    monitor = CrystKit::Features::PowerMonitor.new(CrystKit::Test::FakePowerProvider.new)
    monitor.battery_info.should be_nil
    monitor.on_battery?.should be_false
  end

  it "delivers changes and stops its provider" do
    provider = CrystKit::Test::FakePowerProvider.new
    monitor = CrystKit::Features::PowerMonitor.new(provider)
    channel = monitor.start_monitor
    info = PowerBatteryInfo.new(charging: true, level: 0.75, external_power: true)

    provider.change(info)
    channel.receive.should eq(info)

    monitor.stop_monitor
    provider.running?.should be_false
    channel.closed?.should be_true
  end

  it "closes the previous stream when restarted" do
    provider = CrystKit::Test::FakePowerProvider.new
    monitor = CrystKit::Features::PowerMonitor.new(provider)
    previous = monitor.start_monitor
    current = monitor.start_monitor
    info = PowerBatteryInfo.new(charging: false, level: 0.5, external_power: false)

    previous.closed?.should be_true
    provider.change(info)
    current.receive.should eq(info)
  end
end
