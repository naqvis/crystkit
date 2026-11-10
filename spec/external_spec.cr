require "./spec_helper"
require "uri"
require "../src/features/external"

private class FakeExternalProvider < CrystKit::Features::ExternalProvider
  getter calls = [] of {String, String?}

  def open(target : String, application : String?) : Nil
    @calls << {target, application}
  end
end

private def opener_with_caps : CrystKit::Features::ExternalOpener
  caps = CrystKit::Security::CapabilitySystem.new
  caps.grant("external:open")
  CrystKit::Features::ExternalOpener.new(caps)
end

private def opener_no_caps : CrystKit::Features::ExternalOpener
  caps = CrystKit::Security::CapabilitySystem.new
  CrystKit::Features::ExternalOpener.new(caps)
end

describe CrystKit::Features::ExternalOpener do
  it "delegates validated targets through the injected platform backend" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("external:open")
    provider = FakeExternalProvider.new
    opener = CrystKit::Features::ExternalOpener.new(caps, provider)
    opener.open_url("https://example.com", CrystKit::Features::OpenOptions.new("browser"))
    provider.calls.should eq([{"https://example.com", "browser"}])
  end
  describe "capability enforcement" do
    it "raises SecurityError when external:open capability is missing for open_url" do
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: external:open/) do
        opener_no_caps.open_url("https://example.com")
      end
    end
    it "raises SecurityError when external:open capability is missing for open_file" do
      SpecHelpers.with_temp_file("content") do |path|
        expect_raises(CrystKit::Core::SecurityError, /Missing capability: external:open/) do
          opener_no_caps.open_file(path)
        end
      end
    end
    it "raises SecurityError when external:open capability is missing for open_path" do
      expect_raises(CrystKit::Core::SecurityError, /Missing capability: external:open/) do
        opener_no_caps.open_path("/tmp")
      end
    end
    it "logs a capability violation when external:open is missing" do
      caps = CrystKit::Security::CapabilitySystem.new
      opener = CrystKit::Features::ExternalOpener.new(caps)
      begin
        opener.open_url("https://example.com")
      rescue CrystKit::Core::SecurityError
      end
      caps.violations.size.should eq(1)
      caps.violations[0].capability.should eq("external:open")
    end
    it "raises SecurityError before attempting to open (even for non-existent files)" do
      expect_raises(CrystKit::Core::SecurityError) do
        opener_no_caps.open_file("/nonexistent/file.txt")
      end
    end
  end
  describe "URL validation" do
    it "raises ValidationError for a URL with no scheme" do
      expect_raises(CrystKit::Core::ValidationError, /missing scheme/) do
        opener_with_caps.open_url("example.com")
      end
    end
    it "raises ValidationError for an empty URL" do
      expect_raises(CrystKit::Core::ValidationError) do
        opener_with_caps.open_url("")
      end
    end
    it "raises ValidationError for the javascript: scheme" do
      expect_raises(CrystKit::Core::ValidationError, /Dangerous URL scheme/) do
        opener_with_caps.open_url("javascript:alert(1)")
      end
    end
    it "raises ValidationError for the data: scheme" do
      expect_raises(CrystKit::Core::ValidationError, /Dangerous URL scheme/) do
        opener_with_caps.open_url("data:text/html,<h1>hi</h1>")
      end
    end
    it "raises ValidationError for the vbscript: scheme" do
      expect_raises(CrystKit::Core::ValidationError, /Dangerous URL scheme/) do
        opener_with_caps.open_url("vbscript:MsgBox(1)")
      end
    end
  end
  describe "dangerous file type prevention" do
    it "raises ValidationError for .exe files" do
      SpecHelpers.with_temp_file("") do |path|
        exe_path = path + ".exe"
        File.write(exe_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(exe_path)
          end
        ensure
          File.delete(exe_path) if File.exists?(exe_path)
        end
      end
    end
    it "raises ValidationError for .bat files" do
      SpecHelpers.with_temp_file("") do |path|
        bat_path = path + ".bat"
        File.write(bat_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(bat_path)
          end
        ensure
          File.delete(bat_path) if File.exists?(bat_path)
        end
      end
    end
    it "raises ValidationError for .sh files" do
      SpecHelpers.with_temp_file("") do |path|
        sh_path = path + ".sh"
        File.write(sh_path, "#!/bin/sh")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(sh_path)
          end
        ensure
          File.delete(sh_path) if File.exists?(sh_path)
        end
      end
    end
    it "raises ValidationError for .ps1 files" do
      SpecHelpers.with_temp_file("") do |path|
        ps1_path = path + ".ps1"
        File.write(ps1_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(ps1_path)
          end
        ensure
          File.delete(ps1_path) if File.exists?(ps1_path)
        end
      end
    end
    it "raises ValidationError for .dll files" do
      SpecHelpers.with_temp_file("") do |path|
        dll_path = path + ".dll"
        File.write(dll_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(dll_path)
          end
        ensure
          File.delete(dll_path) if File.exists?(dll_path)
        end
      end
    end
    it "raises ValidationError for .jar files" do
      SpecHelpers.with_temp_file("") do |path|
        jar_path = path + ".jar"
        File.write(jar_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(jar_path)
          end
        ensure
          File.delete(jar_path) if File.exists?(jar_path)
        end
      end
    end
    it "allows safe file types like .txt" do
      SpecHelpers.with_temp_file("hello") do |path|
        txt_path = path + ".txt"
        File.write(txt_path, "hello")
        begin
          ext = File.extname(txt_path).downcase
          CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS.includes?(ext).should be_false
        ensure
          File.delete(txt_path) if File.exists?(txt_path)
        end
      end
    end
    it "allows safe file types like .pdf" do
      SpecHelpers.with_temp_file("%PDF-1.4") do |path|
        pdf_path = path + ".pdf"
        File.write(pdf_path, "%PDF-1.4")
        begin
          ext = File.extname(pdf_path).downcase
          CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS.includes?(ext).should be_false
        ensure
          File.delete(pdf_path) if File.exists?(pdf_path)
        end
      end
    end
    it "extension check is case-insensitive (.EXE is also blocked)" do
      SpecHelpers.with_temp_file("") do |path|
        exe_path = path + ".EXE"
        File.write(exe_path, "")
        begin
          expect_raises(CrystKit::Core::ValidationError, /not allowed for security reasons/) do
            opener_with_caps.open_file(exe_path)
          end
        ensure
          File.delete(exe_path) if File.exists?(exe_path)
        end
      end
    end
  end
  describe "file existence validation" do
    it "raises FileSystemError when the file does not exist" do
      expect_raises(CrystKit::Core::FileSystemError, /File not found/) do
        opener_with_caps.open_file("/nonexistent/path/file.txt")
      end
    end
    it "includes the path in the FileSystemError message" do
      begin
        opener_with_caps.open_file("/no/such/file.txt")
        fail "Expected FileSystemError"
      rescue ex : CrystKit::Core::FileSystemError
        ex.message.not_nil!.should contain("/no/such/file.txt")
      end
    end
  end
  describe "path validation for open_path" do
    it "raises ValidationError for an empty path" do
      expect_raises(CrystKit::Core::ValidationError, /must not be empty/) do
        opener_with_caps.open_path("")
      end
    end
    it "raises ValidationError for a whitespace-only path" do
      expect_raises(CrystKit::Core::ValidationError, /must not be empty/) do
        opener_with_caps.open_path("   ")
      end
    end
  end
end
describe "ExternalOpener::DANGEROUS_EXTENSIONS" do
  it "includes common executable extensions" do
    exts = CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS
    exts.should contain(".exe")
    exts.should contain(".bat")
    exts.should contain(".cmd")
    exts.should contain(".msi")
  end
  it "includes script extensions" do
    exts = CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS
    exts.should contain(".sh")
    exts.should contain(".ps1")
    exts.should contain(".vbs")
    exts.should contain(".js")
  end
  it "includes library extensions" do
    exts = CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS
    exts.should contain(".dll")
    exts.should contain(".so")
    exts.should contain(".dylib")
  end
  it "includes Java archive extension" do
    exts = CrystKit::Features::ExternalOpener::DANGEROUS_EXTENSIONS
    exts.should contain(".jar")
  end
end
