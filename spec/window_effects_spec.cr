require "./spec_helper"
require "../src/features/window_effects"
describe CrystKit::Features::WindowEffects do
  it "is a no-op with null window pointer" do
    effects = CrystKit::Features::WindowEffects.new
    effects.apply(Pointer(Void).null)
  end
  it "is a no-op with all flags false" do
    effects = CrystKit::Features::WindowEffects.new
    effects.apply(Pointer(Void).new(0x1_u64))
  end
  it "requires window:effects capability when capabilities are set" do
    cap_sys = CrystKit::Security::CapabilitySystem.new
    effects = CrystKit::Features::WindowEffects.new(capabilities: cap_sys)
    expect_raises(CrystKit::Core::SecurityError, /window:effects/) do
      effects.apply(Pointer(Void).new(0x1_u64))
    end
  end
  it "passes capability check when granted" do
    cap_sys = CrystKit::Security::CapabilitySystem.new
    cap_sys.grant("window:effects")
    effects = CrystKit::Features::WindowEffects.new(capabilities: cap_sys)
    effects.apply(Pointer(Void).new(0x1_u64))
  end
  it "works without capabilities (nil)" do
    effects = CrystKit::Features::WindowEffects.new
    effects.apply(Pointer(Void).new(0x1_u64))
  end
  it "config is mutable after construction" do
    effects = CrystKit::Features::WindowEffects.new
    effects.config.mica = true
    effects.config.mica?.should be_true
    effects.config.acrylic = true
    effects.config.acrylic?.should be_true
    effects.config.blur_behind = true
    effects.config.blur_behind?.should be_true
  end
end
