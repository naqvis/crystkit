require "./spec_helper"
require "../../src/builder/config"

module CrystKit::Builder
  describe Config do
    describe "JSON serialization" do
      it "serializes and deserializes config" do
        config = Config.new(
          package: PackageSection.new(
            name: "TestApp",
            version: "1.0.0",
            identifier: "com.test.app",
            authors: ["Test Author"],
          ),
          bundle: BundleConfig.new(
            icon: ["icons/icon.png"],
            targets: ["dmg"],
            category: "Development",
          ),
        )

        json = config.to_json
        restored = Config.from_json(json)

        restored.package.name.should eq("TestApp")
        restored.package.version.should eq("1.0.0")
        restored.package.identifier.should eq("com.test.app")
        restored.package.authors.should eq(["Test Author"])
        restored.bundle.icon.should eq(["icons/icon.png"])
        restored.bundle.targets.should eq(["dmg"])
        restored.bundle.category.should eq("Development")
      end

      it "handles empty optional fields" do
        config = Config.new
        json = config.to_json
        restored = Config.from_json(json)
        restored.source_path.should be_nil
      end

      it "handles plugins config" do
        plugins = {"analytics" => JSON::Any.new({"enabled" => JSON::Any.new(true)})}
        config = Config.new(plugins: plugins)
        json = config.to_json
        restored = Config.from_json(json)
        restored.plugins["analytics"].as_h["enabled"].as_bool.should be_true
      end

      it "handles signing config" do
        signing = SigningConfig.new(
          macos: SigningIdentity.new(identity: "Developer ID Application: Test (ABCD)"),
          windows: WindowsSigning.new(certificate_path: "/tmp/cert.pfx", password_env: "CERT_PASS"),
        )
        config = Config.new(
          bundle: BundleConfig.new(signing: signing),
        )
        json = config.to_json
        restored = Config.from_json(json)
        restored.bundle.signing.should_not be_nil
        restored.bundle.signing.not_nil!.macos.not_nil!.identity.should eq("Developer ID Application: Test (ABCD)")
        restored.bundle.signing.not_nil!.windows.not_nil!.certificate_path.should eq("/tmp/cert.pfx")
      end

      it "handles security config" do
        sec = SecurityConfig.new(
          allow_cors: true,
          isolation: true,
          csp: "default-src 'self'",
        )
        config = Config.new(
          app: AppConfigSection.new(security: sec),
        )
        json = config.to_json
        restored = Config.from_json(json)
        restored.app.security.allow_cors?.should be_true
        restored.app.security.isolation?.should be_true
        restored.app.security.csp.should eq("default-src 'self'")
      end
    end

    describe "validation" do
      it "passes for valid config" do
        config = Config.new(
          package: PackageSection.new(
            name: "App",
            version: "0.1.0",
            identifier: "com.example.app",
          ),
        )
        config.validate!
      end

      it "raises for empty name" do
        config = Config.new(
          package: PackageSection.new(name: ""),
        )
        expect_raises(Exception, /name/) { config.validate! }
      end

      it "raises for empty version" do
        config = Config.new(
          package: PackageSection.new(version: ""),
        )
        expect_raises(Exception, /version/) { config.validate! }
      end

      it "raises for empty identifier" do
        config = Config.new(
          package: PackageSection.new(identifier: ""),
        )
        expect_raises(Exception, /identifier/) { config.validate! }
      end

      it "raises for identifier without dots" do
        config = Config.new(
          package: PackageSection.new(identifier: "no-dot"),
        )
        expect_raises(Exception, /dot/) { config.validate! }
      end

      it "raises for empty dev_url" do
        config = Config.new(
          build: BuildConfig.new(dev_url: ""),
          package: PackageSection.new(name: "App", identifier: "com.example.app"),
        )
        expect_raises(Exception, /dev_url/) { config.validate! }
      end

      it "raises for dev_url without http scheme" do
        config = Config.new(
          build: BuildConfig.new(dev_url: "ftp://bad"),
          package: PackageSection.new(name: "App", identifier: "com.example.app"),
        )
        expect_raises(Exception, /http/) { config.validate! }
      end
    end

    describe "to_app_config" do
      it "converts to AppConfig" do
        config = Config.new(
          package: PackageSection.new(
            name: "MyApp",
            version: "2.0.0",
            identifier: "com.my.app",
            authors: ["Dev"],
          ),
        )
        app_config = config.to_app_config
        app_config.name.should eq("MyApp")
        app_config.version.should eq("2.0.0")
        app_config.identifier.should eq("com.my.app")
      end
    end

    describe "BundleConfig" do
      it "has platform-appropriate targets" do
        bc = BundleConfig.new
        bc.targets.should be_a(Array(String))
        bc.targets.should_not be_empty
      end

      it "stores targets" do
        bc = BundleConfig.new(targets: ["dmg"])
        bc.targets.should eq(["dmg"])
      end

      it "stores macOS speech privacy descriptions" do
        bc = BundleConfig.new(
          macos_microphone_usage_description: "Use the microphone",
          macos_speech_recognition_usage_description: "Recognize speech",
        )
        bc.macos_microphone_usage_description.should eq("Use the microphone")
        bc.macos_speech_recognition_usage_description.should eq("Recognize speech")
      end

      it "stores external_bin" do
        bc = BundleConfig.new(
          external_bin: [ExternalBinary.new(name: "helper", path: "./bin")],
        )
        bc.external_bin.size.should eq(1)
        bc.external_bin.first.name.should eq("helper")
        bc.external_bin.first.path.should eq("./bin")
      end
    end

    describe "SigningConfig" do
      it "defaults to nil" do
        bc = BundleConfig.new
        bc.signing.should be_nil
      end

      it "stores macos signing identity" do
        identity = SigningIdentity.new(
          identity: "Developer ID Application: Name (TEAM123)",
          entitlements_path: "./entitlements.plist",
        )
        signing = SigningConfig.new(macos: identity)
        signing.macos.not_nil!.identity.should eq("Developer ID Application: Name (TEAM123)")
        signing.macos.not_nil!.entitlements_path.should eq("./entitlements.plist")
      end

      it "stores windows signing config" do
        ws = WindowsSigning.new(
          certificate_path: "/tmp/cert.p12",
          password_env: "WIN_CERT_PASS",
        )
        ws.certificate_path.should eq("/tmp/cert.p12")
        ws.password_env.should eq("WIN_CERT_PASS")
      end
    end
  end
end
