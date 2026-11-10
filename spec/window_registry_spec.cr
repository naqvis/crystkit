require "./spec_helper"
require "../src/app/app"
require "../src/plugins/builtins/window"
describe CrystKit::Core::WindowRegistry do
  it "is the sole window store used by the window plugin" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      plugin = CrystKit::Plugins::Window.new
      app.plugin(plugin)
      plugin.registry.should be(app.window_registry)
      app.router.invoke_command("window.list", JSON.parse(%({}))).as_a.should be_empty
    end
  end
end
