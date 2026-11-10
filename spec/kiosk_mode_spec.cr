require "./spec_helper"
require "../src/features/kiosk_mode"

private class KioskSpecProvider < CrystKit::Features::KioskMode::Provider
  getter attached_window : Void*?
  getter? active = false
  getter? cleaned = false

  def attach(window : Void*) : Nil
    @attached_window = window
  end

  def enter : Nil
    @active = true
  end

  def exit : Nil
    @active = false
  end

  def active? : Bool
    @active
  end

  def cleanup : Nil
    @active = false
    @cleaned = true
  end
end

describe CrystKit::Features::KioskMode do
  it "binds a window before entering" do
    provider = KioskSpecProvider.new
    kiosk = CrystKit::Features::KioskMode.new(provider)
    window = Pointer(Void).new(42_u64)

    kiosk.enter(window)

    provider.attached_window.should eq(window)
    kiosk.installed?.should be_true
    kiosk.active?.should be_true
  end

  it "does not enter before a window is installed" do
    provider = KioskSpecProvider.new
    kiosk = CrystKit::Features::KioskMode.new(provider)

    kiosk.enter
    kiosk.active?.should be_false
  end

  it "exits and cleans up the bound presentation" do
    provider = KioskSpecProvider.new
    kiosk = CrystKit::Features::KioskMode.new(provider)
    kiosk.enter(Pointer(Void).new(1_u64))

    kiosk.exit
    kiosk.active?.should be_false
    kiosk.cleanup
    kiosk.installed?.should be_false
    provider.cleaned?.should be_true
  end
end
