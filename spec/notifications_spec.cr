require "./spec_helper"
require "../src/features/notifications"
require "../src/features/asset_source"
require "../src/platform/icon_source"
require "virtualfs"

private class RecordingNotificationsProvider < CrystKit::Features::Notifications::Provider
  getter show_calls = [] of Tuple(String, String, String, String, CrystKit::Platform::IconSource?, Int32, Int32, Array({String, String}))

  def request_permission(app_name : String) : Bool
    true
  end

  def close(id : String) : Nil; end

  def show(app_name : String, id : String, title : String, body : String,
           icon : CrystKit::Platform::IconSource?, urgency : Int32, timeout_ms : Int32,
           actions : Array({String, String})) : Nil
    @show_calls << {app_name, id, title, body, icon, urgency, timeout_ms, actions}
  end
end

private def mem_with(files : Hash(String, String)) : VirtualFs::InMemory
  mem = VirtualFs::InMemory.new
  files.each { |p, c| mem.add_file(p, c.to_slice) }
  mem
end

describe CrystKit::Features::Notifications do
  it "passes IconSource.bytes to backend for a VFS icon" do
    vfs = VirtualFs::Vfs.new
    vfs.mount(mem_with({"notif.png" => "PNG"}), "/", priority: 0)
    source = CrystKit::Features::VfsAssetSource.new(vfs)
    provider = RecordingNotificationsProvider.new
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("notification:show")
    notifs = CrystKit::Features::Notifications.new(caps, provider: provider, app_name: "App", asset_source: source)
    notifs.request_permission

    n = CrystKit::Features::Notification.new("T", "B")
    n.icon = Path.new("notif.png")
    notifs.show(n)

    _, _, _, _, icon, _, _, _ = provider.show_calls.first
    icon.should_not be_nil
    icon.not_nil!.bytes?.should be_true
    String.new(icon.not_nil!.bytes.not_nil!).should eq("PNG")
  end

  it "passes IconSource.name for a String icon" do
    provider = RecordingNotificationsProvider.new
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("notification:show")
    notifs = CrystKit::Features::Notifications.new(caps, provider: provider, app_name: "App")
    notifs.request_permission

    n = CrystKit::Features::Notification.new("T", "B")
    n.icon = "dialog-information"
    notifs.show(n)

    _, _, _, _, icon, _, _, _ = provider.show_calls.first
    icon.not_nil!.name?.should be_true
    icon.not_nil!.name.should eq("dialog-information")
  end

  it "passes nil icon when notification has no icon" do
    provider = RecordingNotificationsProvider.new
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("notification:show")
    notifs = CrystKit::Features::Notifications.new(caps, provider: provider, app_name: "App")
    notifs.request_permission

    n = CrystKit::Features::Notification.new("T", "B")
    notifs.show(n)

    _, _, _, _, icon, _, _, _ = provider.show_calls.first
    icon.should be_nil
  end
end
