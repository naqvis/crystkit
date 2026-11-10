require "./spec_helper"
require "../src/crystkit"

describe "Dialog provider delegation" do
  it "delegates open_file to the configured provider" do
    provider = DialogProviderSpy.new
    security = CrystKit::Security::Context.new(
      CrystKit::Security::CapabilitySystem.new,
      CrystKit::Security::ScopeManager.new(Path[File.tempname("dialog_mt")].tap { |p| Dir.mkdir_p(p.to_s) }),
    )
    security.capabilities.grant("dialog:open")
    dialog = CrystKit::Features::FileDialog.new(security, provider: provider)

    path = dialog.open_file(CrystKit::Features::OpenFileOptions.new(title: "Test"))
    provider.called.should eq(:open_file)
    path.try(&.to_s).should eq("/tmp/fake_path.txt")
  end

  it "delegates save_file to the configured provider" do
    provider = DialogProviderSpy.new
    security = CrystKit::Security::Context.new(
      CrystKit::Security::CapabilitySystem.new,
      CrystKit::Security::ScopeManager.new(Path[File.tempname("dialog_mt")].tap { |p| Dir.mkdir_p(p.to_s) }),
    )
    security.capabilities.grant("dialog:save")
    dialog = CrystKit::Features::FileDialog.new(security, provider: provider)

    dialog.save_file(CrystKit::Features::SaveFileOptions.new(title: "Save"))
    provider.called.should eq(:save_file)
  end

  it "delegates messages to the configured provider" do
    provider = DialogProviderSpy.new
    dialog = CrystKit::Features::MessageDialog.new(provider: provider)

    dialog.message(CrystKit::Features::MessageOptions.new(title: "Msg", message: "Hello"))
    provider.called.should eq(:message)
  end
end

private class DialogProviderSpy < CrystKit::Features::DialogProvider
  getter called : Symbol?

  def open_file(options : CrystKit::Features::OpenFileOptions) : String?
    @called = :open_file
    "/tmp/fake_path.txt"
  end

  def open_files(options : CrystKit::Features::OpenFileOptions) : Array(String)
    @called = :open_files
    ["/tmp/fake1.txt", "/tmp/fake2.txt"]
  end

  def save_file(options : CrystKit::Features::SaveFileOptions) : String?
    @called = :save_file
    "/tmp/saved.txt"
  end

  def select_folder(options : CrystKit::Features::FolderOptions) : String?
    @called = :select_folder
    "/tmp/folder"
  end

  def message(title : String, message : String, kind : Int32) : Bool
    @called = :message
    true
  end

  def confirm(title : String, message : String) : Bool
    @called = :confirm
    true
  end
end
