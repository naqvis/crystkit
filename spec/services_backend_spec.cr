require "./spec_helper"
require "../src/platform/services"

module CrystKit::Platform
  describe "Current*Backend hierarchy" do
    it "Services has all backends" do
      services = Services.new
      services.window.should be_a(WindowBackend)
      services.drag_drop.should be_a(DragDropBackend)
      services.printing.should be_a(PrintingBackend)
      services.custom_protocol.should be_a(CustomProtocolBackend)
    end
    it "backends compile without errors (all Current* classes exist)" do
      services = Services.new
      services.should be_a(Services)
    end
  end
end
