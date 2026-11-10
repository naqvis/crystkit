require "./spec_helper"
require "../src/features/system_capabilities"
require "../src/features/system_permissions"
require "../src/features/activations"
require "../src/features/session_lifecycle"
require "../src/plugins/builtins/system_capabilities"
require "../src/plugins/builtins/system_permissions"
require "../src/plugins/builtins/activations"
require "../src/plugins/builtins/session_lifecycle"
require "../src/plugins/builtins/hardware"

private class SystemCapabilityProvider < CrystKit::Features::SystemCapabilities::Provider
  def all : Array(CrystKit::Features::SystemCapability)
    [status("extension.feature")]
  end

  def status(id : String) : CrystKit::Features::SystemCapability
    CrystKit::Features::SystemCapability.new(id, "supported")
  end
end

private class SystemPermissionProvider < CrystKit::Features::SystemPermissions::Provider
  getter requested : String?

  def status(id : String) : CrystKit::Features::SystemPermission
    CrystKit::Features::SystemPermission.new(id, "not-determined", true, true)
  end

  def request(id : String) : CrystKit::Features::SystemPermission
    @requested = id
    CrystKit::Features::SystemPermission.new(id, "granted", false, true)
  end

  def open_settings(id : String) : Bool
    id == "extension.permission"
  end
end

private class ActivationSubscription < CrystKit::Features::Activations::Subscription
  getter? closed = false

  def close : Nil
    @closed = true
  end
end

private class ActivationProvider < CrystKit::Features::Activations::Provider
  getter subscription = ActivationSubscription.new
  @handler : Proc(CrystKit::Features::Activation, Nil)?

  def subscribe(&handler : CrystKit::Features::Activation -> Nil) : CrystKit::Features::Activations::Subscription
    @handler = handler
    subscription
  end

  def emit(event : CrystKit::Features::Activation) : Nil
    @handler.try(&.call(event))
  end
end

describe "system desktop integrations" do
  it "keeps capability and permission identifiers extensible" do
    capabilities = CrystKit::Features::SystemCapabilities.new(SystemCapabilityProvider.new)
    capabilities.status("extension.feature").supported?.should be_true

    provider = SystemPermissionProvider.new
    permissions = CrystKit::Features::SystemPermissions.new(provider)
    permissions.request("extension.permission").state.should eq("granted")
    provider.requested.should eq("extension.permission")
    permissions.open_settings("extension.permission").should be_true
  end

  it "replays cold-start activations and owns subscriptions" do
    provider = ActivationProvider.new
    activations = CrystKit::Features::Activations.new(provider)
    event = CrystKit::Features::Activation.new("extension-activation", ["payload"], Time.utc)
    provider.emit(event)

    received = [] of CrystKit::Features::Activation
    registration = activations.on_event { |activation| received << activation }
    received.should eq([event])

    registration.close
    provider.emit(CrystKit::Features::Activation.new("extension-activation", ["later"], Time.utc))
    received.should eq([event])

    activations.cleanup
    provider.subscription.closed?.should be_true
  end

  it "registers the system plugins through the normal plugin lifecycle" do
    app = CrystKit::App.new
    app.grant("system:info", "permissions:manage", "hardware:list", "hardware:manage")
    app.plugin(CrystKit::Plugins::SystemCapabilities.new)
    app.plugin(CrystKit::Plugins::SystemPermissions.new)
    app.plugin(CrystKit::Plugins::Activations.new)
    app.plugin(CrystKit::Plugins::SessionLifecycle.new)
    app.plugin(CrystKit::Plugins::Hardware.new)
    app.shutdown
  end
end
