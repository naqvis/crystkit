require "./spec_helper"
require "../../src/builder/config"
require "../../src/builder/bundle/linux/deb"
require "../../src/builder/bundle/linux/rpm"
require "../../src/builder/bundle/linux/appimage"
require "../../src/builder/bundle/windows/msi"
require "../../src/builder/bundle/windows/nsis"
require "../../src/builder/bundle/macos/app_bundle"

private def test_config
  CrystKit::Builder::Config.new(
    package: CrystKit::Builder::PackageSection.new(name: "test"),
    bundle: CrystKit::Builder::BundleConfig.new,
  )
end

module CrystKit::Builder::Bundle
  describe MacOS::AppBundle do
    it "writes configured speech privacy descriptions to Info.plist" do
      SpecHelpers.with_temp_dir do |directory|
        binary = File.join(directory, "test")
        File.write(binary, "binary")
        config = CrystKit::Builder::Config.new(
          package: CrystKit::Builder::PackageSection.new(
            name: "test",
            identifier: "dev.crystkit.test"
          ),
          bundle: CrystKit::Builder::BundleConfig.new(
            macos_microphone_usage_description: "Use microphone & audio",
            macos_speech_recognition_usage_description: "Recognize <speech>",
          ),
        )

        app = MacOS::AppBundle.new(config, binary, directory).generate
        plist = File.read(File.join(app, "Contents", "Info.plist"))
        plist.should contain("<key>NSMicrophoneUsageDescription</key>")
        plist.should contain("Use microphone &amp; audio")
        plist.should contain("<key>NSSpeechRecognitionUsageDescription</key>")
        plist.should contain("Recognize &lt;speech&gt;")
      end
    end
  end

  describe Linux::Deb do
    it "stores sidecar_dir and resources_dir" do
      deb = Linux::Deb.new(test_config, "/tmp/binary", "/tmp/output",
        sidecar_dir: "/tmp/sidecars",
        resources_dir: "/tmp/assets")
      deb.sidecar_dir.should eq("/tmp/sidecars")
      deb.resources_dir.should eq("/tmp/assets")
    end

    it "defaults sidecar_dir and resources_dir to nil" do
      deb = Linux::Deb.new(test_config, "/tmp/binary", "/tmp/output")
      deb.sidecar_dir.should be_nil
      deb.resources_dir.should be_nil
    end
  end

  describe Linux::Rpm do
    it "stores sidecar_dir and resources_dir" do
      rpm = Linux::Rpm.new(test_config, "/tmp/binary", "/tmp/output",
        sidecar_dir: "/tmp/sidecars",
        resources_dir: "/tmp/assets")
      rpm.sidecar_dir.should eq("/tmp/sidecars")
      rpm.resources_dir.should eq("/tmp/assets")
    end
  end

  describe Linux::AppImage do
    it "stores sidecar_dir and resources_dir" do
      ai = Linux::AppImage.new(test_config, "/tmp/binary", "/tmp/output",
        sidecar_dir: "/tmp/sidecars",
        resources_dir: "/tmp/assets")
      ai.sidecar_dir.should eq("/tmp/sidecars")
      ai.resources_dir.should eq("/tmp/assets")
    end
  end

  describe Windows::Msi do
    it "stores sidecar_dir and resources_dir" do
      msi = Windows::Msi.new(test_config, "/tmp/binary", "/tmp/output",
        sidecar_dir: "/tmp/sidecars",
        resources_dir: "/tmp/assets")
      msi.sidecar_dir.should eq("/tmp/sidecars")
      msi.resources_dir.should eq("/tmp/assets")
    end
  end

  describe Windows::Nsis do
    it "stores sidecar_dir and resources_dir" do
      nsis = Windows::Nsis.new(test_config, "/tmp/binary", "/tmp/output",
        sidecar_dir: "/tmp/sidecars",
        resources_dir: "/tmp/assets")
      nsis.sidecar_dir.should eq("/tmp/sidecars")
      nsis.resources_dir.should eq("/tmp/assets")
    end
  end
end
