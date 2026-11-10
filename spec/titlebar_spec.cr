require "./spec_helper"
require "../src/features/titlebar"

private class FakeTitlebarProvider < CrystKit::Features::TitlebarProvider
  getter? applied = false
  getter? overlay = false

  def apply(window_ptr : Void*, config : CrystKit::Features::TitlebarConfig) : Nil
    @applied = true
    @overlay = config.overlay?
  end
end

describe CrystKit::Features::Titlebar do
  it "ignores a null window handle" do
    CrystKit::Features::Titlebar.new.apply(Pointer(Void).null)
  end

  it "delegates its configuration to the provider" do
    provider = FakeTitlebarProvider.new
    titlebar = CrystKit::Features::Titlebar.new(
      CrystKit::Features::TitlebarConfig.new(overlay: true),
      provider,
    )

    titlebar.apply(Pointer(Void).new(1_u64))
    provider.applied?.should be_true
    provider.overlay?.should be_true
  end
end
