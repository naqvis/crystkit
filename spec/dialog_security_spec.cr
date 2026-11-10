require "spec"
require "../src/features/dialog"

private class FakeDialogProvider < CrystKit::Features::DialogProvider
  def open_file(options : CrystKit::Features::OpenFileOptions) : String?
    "/trusted/open.txt"
  end

  def open_files(options : CrystKit::Features::OpenFileOptions) : Array(String)
    ["/trusted/one.txt", "/trusted/two.txt"]
  end

  def save_file(options : CrystKit::Features::SaveFileOptions) : String?
    "/trusted/save.txt"
  end

  def select_folder(options : CrystKit::Features::FolderOptions) : String?
    "/trusted/folder"
  end

  def message(title, message, kind) : Bool
    true
  end

  def confirm(title, message) : Bool
    true
  end
end

describe CrystKit::Features::FileDialog do
  it "returns selected paths without persisting scopes" do
    security = CrystKit::Security::Context.new
    security.capabilities.grant("dialog:open")
    security.capabilities.grant("dialog:save")
    dialog = CrystKit::Features::FileDialog.new(security, FakeDialogProvider.new)

    dialog.open_file.should eq(Path["/trusted/open.txt"])
    dialog.open_files.should eq([Path["/trusted/one.txt"], Path["/trusted/two.txt"]])
    dialog.save_file.should eq(Path["/trusted/save.txt"])
    dialog.select_folder.should eq(Path["/trusted/folder"])

    security.scopes.query.should be_empty
  end

  it "requires dialog capability before invoking the backend" do
    dialog = CrystKit::Features::FileDialog.new(CrystKit::Security::Context.new, FakeDialogProvider.new)

    expect_raises(CrystKit::Core::SecurityError) { dialog.open_file }
    expect_raises(CrystKit::Core::SecurityError) { dialog.save_file }
  end
end
