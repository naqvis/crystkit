require "./spec_helper"
require "../src/features/display_manager"

private class DisplaySpecProvider < CrystKit::Features::DisplayManager::Provider
  property displays : Array(NativeDesktop::Display)

  def initialize(@displays = [] of NativeDesktop::Display)
  end

  def all : Array(NativeDesktop::Display)
    @displays.dup
  end
end

private def display(
  name : String,
  bounds : NativeDesktop::Rectangle,
  primary : Bool = false,
  scale_factor : Float64 = 1.0,
) : NativeDesktop::Display
  NativeDesktop::Display.new(
    bounds,
    NativeDesktop::Rectangle.new(bounds.x, bounds.y, bounds.width, bounds.height - 40),
    primary,
    name,
    scale_factor,
  )
end

describe CrystKit::Features::DisplayManager do
  it "converts native display snapshots without querying the operating system" do
    provider = DisplaySpecProvider.new([
      display("Primary", NativeDesktop::Rectangle.new(0, 0, 1920, 1080), primary: true, scale_factor: 2.0),
      display("Left", NativeDesktop::Rectangle.new(-1280, 0, 1280, 1024)),
    ])
    dm = CrystKit::Features::DisplayManager.new(provider)
    monitors = dm.monitors

    monitors.map(&.id).should eq([0, 1])
    monitors.map(&.name).should eq(["Primary", "Left"])
    monitors[0].is_primary?.should be_true
    monitors[0].scale_factor.should eq(2.0)
    monitors[0].bounds.should eq(CrystKit::Features::Rectangle.new(0, 0, 1920, 1080))
    monitors[0].work_area.should eq(CrystKit::Features::Rectangle.new(0, 0, 1920, 1040))
    monitors[1].bounds.x.should eq(-1280)
    dm.monitor_count.should eq(2)
  end

  it "primary_monitor returns the first monitor" do
    provider = DisplaySpecProvider.new([
      display("Primary", NativeDesktop::Rectangle.new(0, 0, 1920, 1080), primary: true),
    ])
    dm = CrystKit::Features::DisplayManager.new(provider)

    dm.primary_monitor.is_primary?.should be_true
  end

  it "does not fabricate a display when the provider returns none" do
    dm = CrystKit::Features::DisplayManager.new(DisplaySpecProvider.new)

    dm.monitors.should be_empty
    dm.monitor_count.should eq(0)
    expect_raises(Enumerable::EmptyError) { dm.primary_monitor }
  end

  it "monitor_at returns nil outside the snapshot" do
    provider = DisplaySpecProvider.new([
      display("Primary", NativeDesktop::Rectangle.new(0, 0, 1920, 1080), primary: true),
    ])
    dm = CrystKit::Features::DisplayManager.new(provider)

    dm.monitor_at(-1).should be_nil
    dm.monitor_at(999).should be_nil
  end
end
