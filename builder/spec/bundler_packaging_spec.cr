require "./spec_helper"
require "../../src/builder/config"
require "../../src/builder/bundle/bundler"
require "../../src/builder/bundle/linux/deb"
require "../../src/builder/bundle/linux/rpm"
require "../../src/builder/bundle/linux/appimage"
require "../../src/builder/bundle/windows/msi"
require "../../src/builder/bundle/windows/nsis"

private def package_config(project_dir : String, targets = [] of String)
  CrystKit::Builder::Config.new(
    package: CrystKit::Builder::PackageSection.new(
      name: "TestApp",
      version: "1.2.3",
      identifier: "com.example.testapp",
      authors: ["Tester <tester@example.com>"]
    ),
    build: CrystKit::Builder::BuildConfig.new(frontend_dist: "./dist"),
    bundle: CrystKit::Builder::BundleConfig.new(targets: targets)
  ).tap do |cfg|
    cfg.source_path = File.join(project_dir, "crystkit.json")
  end
end

private def create_packaging_fixture(root : String)
  binary = File.join(root, "TestApp")
  File.write(binary, "#!/bin/sh\nexit 0\n")
  File.chmod(binary, 0o755)

  assets = File.join(root, "dist")
  Dir.mkdir_p(assets)
  File.write(File.join(assets, "index.html"), "<h1>Test</h1>")

  sidecars = File.join(root, "sidecars")
  Dir.mkdir_p(sidecars)
  helper = File.join(sidecars, "helper")
  File.write(helper, "#!/bin/sh\nexit 0\n")
  File.chmod(helper, 0o755)

  {binary, assets, sidecars}
end

private def with_fake_package_tools(&)
  SpecHelpers.with_temp_dir do |bin_dir|
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{bin_dir}:#{old_path || ""}"
    begin
      yield bin_dir
    ensure
      if old_path
        ENV["PATH"] = old_path
      else
        ENV.delete("PATH")
      end
    end
  end
end

private def write_tool(path : String, body : String)
  File.write(path, "#!/bin/sh\nset -eu\n#{body}\n")
  File.chmod(path, 0o755)
end

{% unless flag?(:win32) %}
  describe "bundle package contents" do
    it "includes assets and sidecars in the deb package tree" do
      SpecHelpers.with_temp_dir do |dir|
        binary, assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        inspect = File.join(dir, "inspect")
        Dir.mkdir_p(inspect)

        with_fake_package_tools do |bin_dir|
          write_tool(File.join(bin_dir, "dpkg-deb"), <<-SH)
build_dir="$2"
deb_path="$3"
cp -R "$build_dir" "#{inspect}/deb"
mkdir -p "$(dirname "$deb_path")"
: > "$deb_path"
SH

          CrystKit::Builder::Bundle::Linux::Deb.new(package_config(dir), binary, output,
            sidecar_dir: sidecars, resources_dir: assets).generate
        end

        File.exists?(File.join(inspect, "deb", "usr", "share", "TestApp", "index.html")).should be_true
        File.exists?(File.join(inspect, "deb", "usr", "share", "TestApp", "sidecars", "helper")).should be_true
      end
    end

    it "declares staged assets and sidecars in the rpm spec" do
      SpecHelpers.with_temp_dir do |dir|
        binary, assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        inspect = File.join(dir, "inspect")
        Dir.mkdir_p(inspect)

        with_fake_package_tools do |bin_dir|
          write_tool(File.join(bin_dir, "rpmbuild"), <<-SH)
for arg in "$@"; do spec_path="$arg"; done
cp "$spec_path" "#{inspect}/testapp.spec"
cp -R "#{output}/TestApp_rpm_build/BUILDROOT/TestApp-1.2.3-1.x86_64" "#{inspect}/buildroot"
touch "#{output}/testapp-1.2.3-1.x86_64.rpm"
SH

          CrystKit::Builder::Bundle::Linux::Rpm.new(package_config(dir), binary, output,
            sidecar_dir: sidecars, resources_dir: assets).generate
        end

        spec = File.read(File.join(inspect, "testapp.spec"))
        spec.should contain("/usr/share/TestApp")
        File.exists?(File.join(inspect, "buildroot", "usr", "share", "TestApp", "index.html")).should be_true
        File.exists?(File.join(inspect, "buildroot", "usr", "share", "TestApp", "sidecars", "helper")).should be_true
      end
    end

    it "places AppImage resources where runtime resource lookup can find them" do
      SpecHelpers.with_temp_dir do |dir|
        binary, assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        inspect = File.join(dir, "inspect")
        Dir.mkdir_p(inspect)

        with_fake_package_tools do |bin_dir|
          write_tool(File.join(bin_dir, "ldd"), "exit 0")
          write_tool(File.join(bin_dir, "appimagetool"), <<-SH)
cp -R "$1" "#{inspect}/AppDir"
: > "$2"
SH

          CrystKit::Builder::Bundle::Linux::AppImage.new(package_config(dir), binary, output,
            sidecar_dir: sidecars, resources_dir: assets).generate
        end

        File.exists?(File.join(inspect, "AppDir", "usr", "share", "TestApp", "index.html")).should be_true
        File.exists?(File.join(inspect, "AppDir", "usr", "share", "TestApp", "sidecars", "helper")).should be_true
        File.read(File.join(inspect, "AppDir", "AppRun")).should start_with("#!/bin/sh\n")
      end
    end

    it "declares assets and sidecars in the generated MSI source" do
      SpecHelpers.with_temp_dir do |dir|
        binary, assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        inspect = File.join(dir, "inspect")
        Dir.mkdir_p(inspect)

        with_fake_package_tools do |bin_dir|
          write_tool(File.join(bin_dir, "candle"), <<-SH)
out=""
prev=""
last=""
for arg in "$@"; do
  if [ "$prev" = "-out" ]; then out="$arg"; fi
  prev="$arg"
  last="$arg"
done
cp "$last" "#{inspect}/app.wxs"
: > "$out"
SH
          write_tool(File.join(bin_dir, "light"), <<-SH)
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-out" ]; then out="$arg"; fi
  prev="$arg"
done
: > "$out"
SH

          CrystKit::Builder::Bundle::Windows::Msi.new(package_config(dir), binary, output,
            sidecar_dir: sidecars, resources_dir: assets).generate
        end

        wxs = File.read(File.join(inspect, "app.wxs"))
        wxs.should contain("index.html")
        wxs.should contain("sidecars")
        wxs.should contain("helper")
      end
    end

    it "installs the whole resource tree in the generated NSIS script" do
      SpecHelpers.with_temp_dir do |dir|
        binary, assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        inspect = File.join(dir, "inspect")
        Dir.mkdir_p(inspect)

        with_fake_package_tools do |bin_dir|
          write_tool(File.join(bin_dir, "makensis"), <<-SH)
script_path=""
for arg in "$@"; do
  script_path="$arg"
  case "$arg" in
    /DOutFile=*) out="${arg#/DOutFile=}" ;;
  esac
done
cp "$script_path" "#{inspect}/installer.nsi"
cp -R "#{output}/nsis_work" "#{inspect}/work"
: > "$out"
SH

          CrystKit::Builder::Bundle::Windows::Nsis.new(package_config(dir), binary, output,
            sidecar_dir: sidecars, resources_dir: assets).generate
        end

        script = File.read(File.join(inspect, "installer.nsi"))
        script.should contain("resources")
        File.exists?(File.join(inspect, "work", "resources", "index.html")).should be_true
        File.exists?(File.join(inspect, "work", "resources", "sidecars", "helper")).should be_true
      end
    end

    it "uses the shared resource tree in portable bundles" do
      SpecHelpers.with_temp_dir do |dir|
        binary, _assets, sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        cfg = package_config(dir, ["portable"])
        cfg.bundle.external_bin = [CrystKit::Builder::ExternalBinary.new(name: "helper", path: sidecars)]

        bundler = CrystKit::Builder::Bundle::Bundler.new(cfg, binary, output)
        result = bundler.bundle(["portable"])
        File.exists?(File.join(result["portable"], "resources", "assets.vpak")).should be_true
        File.exists?(File.join(result["portable"], "resources", "sidecars", "helper")).should be_true
      end
    end

    it "raises when a requested target cannot be packaged" do
      SpecHelpers.with_temp_dir do |dir|
        binary, _assets, _sidecars = create_packaging_fixture(dir)
        output = File.join(dir, "out")
        cfg = package_config(dir)
        bundler = CrystKit::Builder::Bundle::Bundler.new(cfg, binary, output)

        expect_raises(Exception, /definitely-not-a-real-target/) do
          bundler.bundle(["definitely-not-a-real-target"])
        end
      end
    end
  end
{% else %}
  pending "bundler packaging specs (shell-based, not supported on Windows)"
{% end %}
