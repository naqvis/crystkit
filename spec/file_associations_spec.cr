require "./spec_helper"

private class FileAssociationProvider < CrystKit::Features::FileAssociations::Provider
  getter registered = [] of NativeDesktop::FileAssociation
  getter unregistered = [] of NativeDesktop::FileAssociation
  property fail_mime_type : String?
  property fail_unregister = false

  def register(association : NativeDesktop::FileAssociation) : Nil
    raise "register failed" if association.mime_type == @fail_mime_type
    @registered << association
  end

  def unregister(association : NativeDesktop::FileAssociation) : Nil
    raise "unregister failed" if @fail_unregister
    @unregistered << association
  end
end

private def file_association_executable
  (Path[Dir.current] / "example-editor").expand
end

private def file_association_document(name : String)
  (Path[Dir.current] / name).expand
end

private def file_associations(provider = FileAssociationProvider.new)
  CrystKit::Features::FileAssociations.new(
    "dev.example.editor",
    "Example Editor",
    file_association_executable,
    provider,
  )
end

describe CrystKit::Features::FileAssociations do
  it "registers an application-owned native file association" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)

    result = files.register(" MD ", " TEXT/MARKDOWN ", "Markdown Document")

    result.extension.should eq(".md")
    result.mime_type.should eq("text/markdown")
    provider.registered.size.should eq(1)
    native = provider.registered.first
    native.application_id.should eq("dev.example.editor")
    native.application_name.should eq("Example Editor")
    native.executable.should eq(file_association_executable)
  end

  it "does not repeat an unchanged registration" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)

    2.times { files.register(".md", "text/markdown", "Markdown Document") }

    provider.registered.size.should eq(1)
    provider.unregistered.should be_empty
  end

  it "replaces an existing extension registration" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)
    files.register(".md", "text/markdown", "Markdown Document")

    files.register(".md", "text/x-markdown", "Markdown Source")

    provider.unregistered.map(&.mime_type).should eq(["text/markdown"])
    provider.registered.map(&.mime_type).should eq(["text/markdown", "text/x-markdown"])
    files.associations.first.mime_type.should eq("text/x-markdown")
  end

  it "restores the previous registration when replacement fails" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)
    files.register(".md", "text/markdown", "Markdown Document")
    provider.fail_mime_type = "text/x-markdown"

    error = expect_raises(CrystKit::Core::Error) do
      files.register(".md", "text/x-markdown", "Markdown Source")
    end

    error.code.should eq("FILE_ASSOCIATION_REGISTER_FAILED")
    provider.registered.map(&.mime_type).should eq(["text/markdown", "text/markdown"])
    files.associations.first.mime_type.should eq("text/markdown")
  end

  it "unregisters only file types owned by the feature" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)
    files.register(".md", "text/markdown", "Markdown Document")

    files.unregister("md").should be_true
    files.unregister("md").should be_false
    files.registered?(".md").should be_false
    provider.unregistered.map(&.extension).should eq([".md"])
  end

  it "wraps native unregistration errors" do
    provider = FileAssociationProvider.new
    files = file_associations(provider)
    files.register(".md", "text/markdown", "Markdown Document")
    provider.fail_unregister = true

    error = expect_raises(CrystKit::Core::Error) { files.unregister(".md") }

    error.code.should eq("FILE_ASSOCIATION_UNREGISTER_FAILED")
    files.registered?(".md").should be_true
  end

  it "dispatches only registered file types to open handlers" do
    files = file_associations
    files.register(".md", "text/markdown", "Markdown Document")
    opened = [] of Path
    files.on_open { |path| opened << path }

    readme = file_association_document("README.md")
    other = file_association_document("other.md")
    image = file_association_document("image.png")

    files.handle_open(readme).should be_true
    files.handle_open(image).should be_false
    files.handle_arguments(["--verbose", other.to_s, image.to_s]).should eq(1)
    opened.should eq([readme, other])
  end

  it "generates bundle metadata from registered types" do
    files = file_associations
    files.register(".md", "text/markdown", "Markdown & Notes")
    files.register(".markdown", "text/markdown", "Markdown Document")

    plist = files.to_macos_plist_entries.join
    plist.should contain("Markdown &amp; Notes")
    plist.should contain("<string>Alternate</string>")
    files.to_linux_desktop_mime.should eq("MimeType=text/markdown;")
  end

  it "loads registrations from a prior application run for removal" do
    SpecHelpers.with_temp_dir do |directory|
      storage = Path[directory] / "file-associations.json"
      first_provider = FileAssociationProvider.new
      first = CrystKit::Features::FileAssociations.new(
        "dev.example.editor",
        "Example Editor",
        file_association_executable,
        first_provider,
        storage,
      )
      first.register(".md", "text/markdown", "Markdown Document")

      second_provider = FileAssociationProvider.new
      second = CrystKit::Features::FileAssociations.new(
        "dev.example.editor",
        "Example Editor",
        file_association_executable,
        second_provider,
        storage,
      )

      second.registered?(".md").should be_true
      second.unregister(".md").should be_true
      second_provider.unregistered.map(&.mime_type).should eq(["text/markdown"])
      File.read(storage).should eq("[]")
    end
  end
end

describe CrystKit::App do
  it "owns one file-association feature" do
    app = CrystKit::App.new(CrystKit::AppConfig.new(
      name: "Example Editor",
      identifier: "dev.example.editor",
    ))

    app.file_associations.should be(app.file_associations)
    app.file_associations.application_id.should eq("dev.example.editor")
    app.file_associations.application_name.should eq("Example Editor")
  ensure
    app.try(&.shutdown)
  end
end
