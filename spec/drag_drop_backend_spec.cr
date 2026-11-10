require "./spec_helper"
require "../src/app/app"
require "../src/plugins/builtins/drag_drop"

private class RecordingDragDropBackend < CrystKit::Platform::DragDropBackend
  getter attached = [] of String
  getter detached = [] of String

  @over = {} of String => Proc(Array(String), String?, Nil)
  @drop = {} of String => Proc(Array(String), String?, Nil)

  def attach(
    window : CrystKit::Core::Window,
    on_over : Proc(Array(String), String?, Nil),
    on_drop : Proc(Array(String), String?, Nil),
  ) : Nil
    @attached << window.id
    @over[window.id] = on_over
    @drop[window.id] = on_drop
  end

  def detach(window_id : String) : Nil
    @detached << window_id
    @over.delete(window_id)
    @drop.delete(window_id)
  end

  def simulate_over(window_id : String, files : Array(String), text : String? = nil) : Nil
    @over[window_id].call(files, text)
  end

  def simulate_drop(window_id : String, files : Array(String), text : String? = nil) : Nil
    @drop[window_id].call(files, text)
  end
end

private def inert_window(label : String) : CrystKit::Core::Window
  CrystKit::Core::Window.new(CrystKit::Core::EnhancedWindow.allocate, label: label)
end

describe CrystKit::Plugins::DragDrop do
  it "attaches every window and emits canonical events with the source window" do
    SpecHelpers.with_temp_dir do |dir|
      backend = RecordingDragDropBackend.new
      platform = CrystKit::Platform::Services.new(drag_drop: backend)
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]), platform)
      plugin = CrystKit::Plugins::DragDrop.new
      drops = [] of JSON::Any
      overs = [] of JSON::Any

      app.plugin(plugin)
      app.on("drag.drop") { |payload| drops << payload }
      app.on("drag.over") { |payload| overs << payload }

      main = inert_window("main")
      dock = inert_window("quick-dock")
      plugin.on_window_created(main)
      plugin.on_window_created(dock)

      backend.attached.should eq([main.id, dock.id])

      backend.simulate_over(main.id, ["/tmp/input.mov"])
      backend.simulate_drop(dock.id, [] of String, "plain text")

      overs.should eq([JSON.parse(%({"files":["/tmp/input.mov"],"text":null,"window":"main"}))])
      drops.should eq([JSON.parse(%({"files":[],"text":"plain text","window":"quick-dock"}))])

      main.emit_lifecycle("destroy")
      backend.detached.should contain(main.id)
    end
  end
end
