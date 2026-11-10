require "./spec_helper"
require "../src/features/taskbar_progress"

private class TaskbarSpecProvider < CrystKit::Features::TaskbarProgress::Provider
  getter attached_window : Void*?
  getter application_id : String?
  getter progress_value : Float64?
  getter state_value : CrystKit::Features::TaskbarProgress::ProgressState?
  getter badge_value : String?
  getter overlay_value : CrystKit::Platform::IconSource?
  getter? cleared = false
  getter? cleaned = false

  def attach(window : Void*, application_id : String) : Nil
    @attached_window = window
    @application_id = application_id
  end

  def progress=(value : Float64) : Nil
    @progress_value = value
  end

  def clear_progress : Nil
    @cleared = true
  end

  def badge=(text : String?) : Nil
    @badge_value = text
  end

  def overlay_icon=(icon : CrystKit::Platform::IconSource?) : Nil
    @overlay_value = icon
  end

  def state=(state : CrystKit::Features::TaskbarProgress::ProgressState) : Nil
    @state_value = state
  end

  def cleanup : Nil
    @cleaned = true
  end
end

describe CrystKit::Features::TaskbarProgress do
  it "caches state and replays it when attached" do
    provider = TaskbarSpecProvider.new
    taskbar = CrystKit::Features::TaskbarProgress.new(provider)
    icon = CrystKit::Platform::IconSource.name("information")
    taskbar.progress = 0.65
    taskbar.progress_state = CrystKit::Features::TaskbarProgress::ProgressState::Normal
    taskbar.badge = "4"
    taskbar.overlay_icon = icon

    taskbar.install(Pointer(Void).new(42_u64), "com.example.app")

    taskbar.installed?.should be_true
    provider.attached_window.should eq(Pointer(Void).new(42_u64))
    provider.application_id.should eq("com.example.app")
    provider.progress_value.should eq(0.65)
    provider.state_value.should eq(CrystKit::Features::TaskbarProgress::ProgressState::Normal)
    provider.badge_value.should eq("4")
    provider.overlay_value.should eq(icon)
  end

  it "clamps progress and ignores non-finite values" do
    taskbar = CrystKit::Features::TaskbarProgress.new(TaskbarSpecProvider.new)
    taskbar.progress = 2.0
    taskbar.progress.should eq(1.0)
    taskbar.progress = -2.0
    taskbar.progress.should eq(0.0)
    taskbar.progress = Float64::NAN
    taskbar.progress.should eq(0.0)
  end

  it "clears state and releases its provider" do
    provider = TaskbarSpecProvider.new
    taskbar = CrystKit::Features::TaskbarProgress.new(provider)
    taskbar.install(Pointer(Void).new(1_u64), "com.example.app")
    taskbar.progress = 0.5
    taskbar.progress_state = CrystKit::Features::TaskbarProgress::ProgressState::Error

    taskbar.clear_progress
    taskbar.progress.should eq(0.0)
    taskbar.progress_state.should eq(CrystKit::Features::TaskbarProgress::ProgressState::NoProgress)
    provider.cleared?.should be_true

    taskbar.cleanup
    taskbar.installed?.should be_false
    provider.cleaned?.should be_true
  end
end
