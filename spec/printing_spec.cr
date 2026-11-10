require "./spec_helper"
require "../src/features/printing"

describe CrystKit::Features::PrintOptions do
  it "serializes to JSON" do
    opts = CrystKit::Features::PrintOptions.new(copies: 2, landscape: true)
    json = opts.to_json
    json.should contain("\"copies\":2")
    json.should contain("\"landscape\":true")
  end

  it "deserializes from JSON" do
    json = %({"copies":3,"paper_size":"Letter","landscape":true,"color":true,"scale":1.0,"margins_top":20.0,"margins_right":20.0,"margins_bottom":20.0,"margins_left":20.0})
    opts = CrystKit::Features::PrintOptions.from_json(json)
    opts.copies.should eq(3)
    opts.paper_size.should eq("Letter")
    opts.landscape?.should be_true
    opts.color?.should be_true
  end
end

describe CrystKit::Features::Printer do
  it "requires printing:print capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    printer = CrystKit::Features::Printer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /printing:print/) do
      printer.print(Pointer(Void).new(0_u64))
    end
  end

  it "requires printing:pdf capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    printer = CrystKit::Features::Printer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /printing:pdf/) do
      printer.print_to_pdf(Pointer(Void).new(0_u64), "/tmp/test.pdf")
    end
  end

  it "requires printing:info for list_printers" do
    caps = CrystKit::Security::CapabilitySystem.new
    printer = CrystKit::Features::Printer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /printing:info/) do
      printer.list_printers
    end
  end

  it "requires printing:print for show_dialog" do
    caps = CrystKit::Security::CapabilitySystem.new
    printer = CrystKit::Features::Printer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /printing:print/) do
      printer.show_dialog(Pointer(Void).new(0_u64))
    end
  end

  it "returns false for print without capabilities" do
    printer = CrystKit::Features::Printer.new
    result = printer.print(Pointer(Void).new(0_u64))
    result.should be_false
  end

  it "returns false for print_to_pdf without capabilities" do
    printer = CrystKit::Features::Printer.new
    result = printer.print_to_pdf(Pointer(Void).new(0_u64), "/tmp/test.pdf")
    result.should be_false
  end

  it "returns empty array for list_printers without capabilities" do
    printer = CrystKit::Features::Printer.new
    result = printer.list_printers
    result.should be_a(Array(String))
  end

  it "returns false for show_dialog without capabilities" do
    printer = CrystKit::Features::Printer.new
    result = printer.show_dialog(Pointer(Void).new(0_u64))
    result.should be_false
  end
end
