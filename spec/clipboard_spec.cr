require "./spec_helper"
require "../src/features/clipboard"
require "../src/security/capability"

describe CrystKit::Features::Clipboard do
  it "raises when reading without clipboard:read capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    cb = CrystKit::Features::Clipboard.new(caps, CrystKit::Test::FakeClipboardProvider.new)
    expect_raises(CrystKit::Core::SecurityError) do
      cb.read_text
    end
  end

  it "raises when writing without clipboard:write capability" do
    caps = CrystKit::Security::CapabilitySystem.new
    cb = CrystKit::Features::Clipboard.new(caps, CrystKit::Test::FakeClipboardProvider.new)
    expect_raises(CrystKit::Core::SecurityError) do
      cb.write_text("test")
    end
  end

  it "round-trips text through the backend" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:read")
    caps.grant("clipboard:write")
    backend = CrystKit::Test::FakeClipboardProvider.new
    cb = CrystKit::Features::Clipboard.new(caps, backend)

    test_text = "Round-trip test"
    cb.write_text(test_text)
    backend.text.should eq(test_text)
    cb.read_text.should eq(test_text)
  end

  it "rejects text exceeding MAX_TEXT_SIZE" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:write")
    cb = CrystKit::Features::Clipboard.new(caps, CrystKit::Test::FakeClipboardProvider.new)
    expect_raises(CrystKit::Core::Error, /CLIPBOARD_TEXT_TOO_LARGE/) do
      cb.write_text("x" * (CrystKit::Features::Clipboard::MAX_TEXT_SIZE + 1))
    end
  end

  it "reads image wrapped as ClipboardImage" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:read")
    backend = CrystKit::Test::FakeClipboardProvider.new
    backend.write_image("PNGDATA".to_slice)
    cb = CrystKit::Features::Clipboard.new(caps, backend)
    result = cb.read_image
    result.should_not be_nil
    result.not_nil!.data.should eq("PNGDATA".to_slice)
    result.not_nil!.format.should eq(CrystKit::Features::ImageFormat::PNG)
  end

  it "reads HTML and RTF from the backend" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:read")
    backend = CrystKit::Test::FakeClipboardProvider.new
    backend.write_html("<b>hi</b>")
    backend.write_rtf("{\\rtf1}")
    cb = CrystKit::Features::Clipboard.new(caps, backend)
    cb.read_html.should eq("<b>hi</b>")
    cb.read_rtf.should eq("{\\rtf1}")
  end

  it "clears the backend contents" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:write")
    backend = CrystKit::Test::FakeClipboardProvider.new
    backend.write_text("data")
    cb = CrystKit::Features::Clipboard.new(caps, backend)
    cb.clear
    backend.cleared?.should be_true
    backend.text.should eq("")
  end

  it "rejects image with empty data" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("clipboard:write")
    cb = CrystKit::Features::Clipboard.new(caps, CrystKit::Test::FakeClipboardProvider.new)
    expect_raises(CrystKit::Core::Error, /CLIPBOARD_INVALID_IMAGE/) do
      cb.write_image(CrystKit::Features::ClipboardImage.new(Bytes.empty, 0, 0, CrystKit::Features::ImageFormat::PNG))
    end
  end

  it "invokes the registered change handler via handle_change" do
    caps = CrystKit::Security::CapabilitySystem.new
    cb = CrystKit::Features::Clipboard.new(caps, CrystKit::Test::FakeClipboardProvider.new)
    changed = false
    cb.on_change { changed = true }
    cb.handle_change
    changed.should be_true
  end
end
