require "./spec_helper"
require "./ipc_bridge_spec"
require "../src/app/app"
require "../src/plugins/base"

private class CoercionPlugin < CrystKit::Plugin::Base
  getter context : CrystKit::Plugin::Context?

  def identifier : String
    "coercion"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      commands: %w[
        plugin.command.normal
        plugin.command.raise_core
        plugin.command.raise_only
        plugin.command_1arg.normal
        plugin.command_1arg.raise_core
        plugin.command_1arg.raise_only
        plugin.command_multi.normal
        plugin.command_multi.raise_core
        plugin.command_multi.raise_only
        plugin.async.normal
        plugin.async.raise_core
        plugin.async.raise_only
        plugin.async_1arg_notoken.normal
        plugin.async_1arg_notoken.raise_core
        plugin.async_1arg_notoken.raise_only
        plugin.async_multi.normal
        plugin.async_multi.raise_core
        plugin.async_multi.raise_only
      ],
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    @context = context
    context.command("plugin.command.normal") { 101 }
    context.command("plugin.command.raise_core") do
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.command("plugin.command.raise_only") do
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
    context.command("plugin.command_1arg.normal", Int32) { |x| x * 2 }
    context.command("plugin.command_1arg.raise_core", Int32) do |_x|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.command("plugin.command_1arg.raise_only", Int32) do |_x|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
    context.command("plugin.command_multi.normal", Int32, Int32) { |a, b| a + b }
    context.command("plugin.command_multi.raise_core", Int32, Int32) do |_a, _b|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.command("plugin.command_multi.raise_only", Int32, Int32) do |_a, _b|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
    context.async("plugin.async.normal") { 202 }
    context.async("plugin.async.raise_core") do
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.async("plugin.async.raise_only") do
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
    context.async("plugin.async_1arg_notoken.normal", Int32) { |x| x * 3 }
    context.async("plugin.async_1arg_notoken.raise_core", Int32) do |_x|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.async("plugin.async_1arg_notoken.raise_only", Int32) do |_x|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
    context.async("plugin.async_multi.normal", Int32, Int32) { |a, b, _t| a * b }
    context.async("plugin.async_multi.raise_core", Int32, Int32) do |_a, _b, _t|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      0
    end
    context.async("plugin.async_multi.raise_only", Int32, Int32) do |_a, _b, _t|
      raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
    end
  end
end

private def make_app : CrystKit::App
  storage = Path[File.tempname("ipc_coercion_spec")]
  config = CrystKit::AppConfig.new(
    identifier: "test.app.coercion.#{Random.rand(100_000)}",
    storage_dir: storage,
  )
  CrystKit::App.new(config)
end

private def invoke_sync(host : SpecIPC::BridgeHost, command : String, params : JSON::Any?) : CrystKit::IPC::ResponseEnvelope
  SpecIPC.invoke_sync(host, command, params)
end

private def invoke_async(host : SpecIPC::BridgeHost, command : String, params : JSON::Any?) : CrystKit::IPC::ResponseEnvelope
  SpecIPC.invoke_async(host, command, params)
end

private def expect_normal(envelope, expected_int : Int32) : Nil
  envelope.ok?.should be_true,
    "normal handler should succeed, got error: #{envelope.error.try(&.code)} #{envelope.error.try(&.message)}"
  envelope.value.not_nil!.as_i.should eq(expected_int)
end

private def expect_boom(envelope) : Nil
  envelope.ok?.should be_false,
    "raise handler should fail, got value: #{envelope.value.try(&.inspect)}"
  envelope.error.not_nil!.code.should eq("BOOM"),
    "Core::IPCError code should survive end-to-end, got: #{envelope.error.try(&.code).inspect}"
end

private MATRIX = [
  {owner: :app, shape: :normal, cmd: "app.command.normal", params: JSON.parse(%({})), expected: 101, bridge: :sync},
  {owner: :app, shape: :raise_core, cmd: "app.command.raise_core", params: JSON.parse(%({})), expected: nil, bridge: :sync},
  {owner: :app, shape: :raise_only, cmd: "app.command.raise_only", params: JSON.parse(%({})), expected: nil, bridge: :sync},
  {owner: :app, shape: :normal, cmd: "app.command_1arg.normal", params: JSON.parse(%(21)), expected: 42, bridge: :sync},
  {owner: :app, shape: :raise_core, cmd: "app.command_1arg.raise_core", params: JSON.parse(%(21)), expected: nil, bridge: :sync},
  {owner: :app, shape: :raise_only, cmd: "app.command_1arg.raise_only", params: JSON.parse(%(21)), expected: nil, bridge: :sync},
  {owner: :app, shape: :normal, cmd: "app.command_multi.normal", params: JSON.parse(%([20,22])), expected: 42, bridge: :sync},
  {owner: :app, shape: :raise_core, cmd: "app.command_multi.raise_core", params: JSON.parse(%([20,22])), expected: nil, bridge: :sync},
  {owner: :app, shape: :raise_only, cmd: "app.command_multi.raise_only", params: JSON.parse(%([20,22])), expected: nil, bridge: :sync},
  {owner: :app, shape: :normal, cmd: "app.async.normal", params: JSON::Any.new(nil), expected: 202, bridge: :async},
  {owner: :app, shape: :raise_core, cmd: "app.async.raise_core", params: JSON::Any.new(nil), expected: nil, bridge: :async},
  {owner: :app, shape: :raise_only, cmd: "app.async.raise_only", params: JSON::Any.new(nil), expected: nil, bridge: :async},
  {owner: :app, shape: :normal, cmd: "app.async_1arg_token.normal", params: JSON.parse(%(7)), expected: 21, bridge: :async},
  {owner: :app, shape: :raise_core, cmd: "app.async_1arg_token.raise_core", params: JSON.parse(%(7)), expected: nil, bridge: :async},
  {owner: :app, shape: :raise_only, cmd: "app.async_1arg_token.raise_only", params: JSON.parse(%(7)), expected: nil, bridge: :async},
  {owner: :app, shape: :normal, cmd: "app.async_multi.normal", params: JSON.parse(%([6,7])), expected: 42, bridge: :async},
  {owner: :app, shape: :raise_core, cmd: "app.async_multi.raise_core", params: JSON.parse(%([6,7])), expected: nil, bridge: :async},
  {owner: :app, shape: :raise_only, cmd: "app.async_multi.raise_only", params: JSON.parse(%([6,7])), expected: nil, bridge: :async},
  {owner: :plugin, shape: :normal, cmd: "plugin.command.normal", params: JSON.parse(%({})), expected: 101, bridge: :sync},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.command.raise_core", params: JSON.parse(%({})), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.command.raise_only", params: JSON.parse(%({})), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :normal, cmd: "plugin.command_1arg.normal", params: JSON.parse(%(21)), expected: 42, bridge: :sync},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.command_1arg.raise_core", params: JSON.parse(%(21)), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.command_1arg.raise_only", params: JSON.parse(%(21)), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :normal, cmd: "plugin.command_multi.normal", params: JSON.parse(%([20,22])), expected: 42, bridge: :sync},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.command_multi.raise_core", params: JSON.parse(%([20,22])), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.command_multi.raise_only", params: JSON.parse(%([20,22])), expected: nil, bridge: :sync},
  {owner: :plugin, shape: :normal, cmd: "plugin.async.normal", params: JSON::Any.new(nil), expected: 202, bridge: :async},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.async.raise_core", params: JSON::Any.new(nil), expected: nil, bridge: :async},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.async.raise_only", params: JSON::Any.new(nil), expected: nil, bridge: :async},
  {owner: :plugin, shape: :normal, cmd: "plugin.async_1arg_notoken.normal", params: JSON.parse(%(7)), expected: 21, bridge: :async},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.async_1arg_notoken.raise_core", params: JSON.parse(%(7)), expected: nil, bridge: :async},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.async_1arg_notoken.raise_only", params: JSON.parse(%(7)), expected: nil, bridge: :async},
  {owner: :plugin, shape: :normal, cmd: "plugin.async_multi.normal", params: JSON.parse(%([6,7])), expected: 42, bridge: :async},
  {owner: :plugin, shape: :raise_core, cmd: "plugin.async_multi.raise_core", params: JSON.parse(%([6,7])), expected: nil, bridge: :async},
  {owner: :plugin, shape: :raise_only, cmd: "plugin.async_multi.raise_only", params: JSON.parse(%([6,7])), expected: nil, bridge: :async},
] of {owner: Symbol, shape: Symbol, cmd: String, params: JSON::Any, expected: Int32?, bridge: Symbol}
describe "IPC handler coercion matrix" do
  MATRIX.each do |entry|
    owner = entry[:owner]
    shape = entry[:shape]
    cmd = entry[:cmd]
    params = entry[:params]
    expected = entry[:expected]
    bridge = entry[:bridge]
    it "#{owner}: #{cmd} (#{shape}, #{bridge})" do
      SpecHelpers.with_temp_dir do |dir|
        app = CrystKit::App.new(CrystKit::AppConfig.new(
          identifier: "test.app.coerce.#{Random.rand(100_000)}",
          storage_dir: Path[dir],
        ))
        if owner == :app
          app.command("app.command.normal") { 101 }
          app.command("app.command.raise_core") do
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.command("app.command.raise_only") do
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
          app.command("app.command_1arg.normal", Int32) { |x| x * 2 }
          app.command("app.command_1arg.raise_core", Int32) do |_x|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.command("app.command_1arg.raise_only", Int32) do |_x|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
          app.command("app.command_multi.normal", Int32, Int32) { |a, b| a + b }
          app.command("app.command_multi.raise_core", Int32, Int32) do |_a, _b|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.command("app.command_multi.raise_only", Int32, Int32) do |_a, _b|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
          app.async("app.async.normal") { 202 }
          app.async("app.async.raise_core") do
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.async("app.async.raise_only") do
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
          app.async("app.async_1arg_token.normal", Int32) { |x, _t| x * 3 }
          app.async("app.async_1arg_token.raise_core", Int32) do |_x, _t|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.async("app.async_1arg_token.raise_only", Int32) do |_x, _t|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
          app.async("app.async_multi.normal", Int32, Int32) { |a, b, _t| a * b }
          app.async("app.async_multi.raise_core", Int32, Int32) do |_a, _b, _t|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
            0
          end
          app.async("app.async_multi.raise_only", Int32, Int32) do |_a, _b, _t|
            raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
          end
        else
          app.plugin(CoercionPlugin.new)
        end
        host = SpecIPC::BridgeHost.new
        host.setup_ipc_client(app.router)
        envelope = case bridge
                   when :sync
                     invoke_sync(host, cmd, params)
                   when :async
                     invoke_async(host, cmd, params)
                   else
                     raise "unknown bridge: #{bridge}"
                   end
        case shape
        when :normal
          expect_normal(envelope, expected.not_nil!)
        when :raise_core, :raise_only
          expect_boom(envelope)
        else
          raise "unknown shape: #{shape}"
        end
      end
    end
  end
end
