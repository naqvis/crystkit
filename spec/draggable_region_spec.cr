require "./spec_helper"
require "../src/features/draggable_region"

describe CrystKit::Features::DraggableRegion do
  it "generates JS bridge code" do
    js = CrystKit::Features::DraggableRegion.js_bridge
    js.should be_a(String)
    js.should contain("__CRYSTKIT_IPC__")
    js.should contain("data-cryst-drag")
  end
end
