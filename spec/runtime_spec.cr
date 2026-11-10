require "./spec_helper"
require "../src/app/app"
require "../src/plugins/builtins/dialog"
require "../src/plugins/builtins/system_info"

private class OwnedCommandPlugin < CrystKit::Plugin::Base
  struct EchoRequest
    include JSON::Serializable

    getter value : String

    def initialize(@value : String)
    end
  end

  def identifier : String
    "owned"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      commands: %w(owned.ping owned.echo owned.join owned.identity),
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command("owned.ping") { "pong" }
    context.command("owned.echo", EchoRequest, &.value)
    context.command("owned.join", String, String) do |prefix, suffix|
      "#{prefix}#{suffix}"
    end
    context.command_context("owned.identity") do |invocation, _params|
      invocation.plugin_id || "none"
    end
  end
end

private class UndeclaredCommandPlugin < CrystKit::Plugin::Base
  def identifier : String
    "undeclared_command"
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command("undeclared_command.ping") { "pong" }
  end
end

private class UndeclaredEventPlugin < CrystKit::Plugin::Base
  def identifier : String
    "undeclared_event"
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.emit("undeclared_event.changed", JSON::Any.new(nil))
  end
end

private class RuntimeDialogProvider < CrystKit::Features::DialogProvider
  getter messages = [] of String

  def open_file(options : CrystKit::Features::OpenFileOptions) : String?
    nil
  end

  def open_files(options : CrystKit::Features::OpenFileOptions) : Array(String)
    [] of String
  end

  def save_file(options : CrystKit::Features::SaveFileOptions) : String?
    nil
  end

  def select_folder(options : CrystKit::Features::FolderOptions) : String?
    nil
  end

  def message(title, message, kind) : Bool
    @messages << message
    true
  end

  def confirm(title, message) : Bool
    true
  end
end

private class TooManyCommandsPlugin < CrystKit::Plugin::Base
  def identifier : String
    "too_many"
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    101.times do |index|
      context.command("too_many.command_#{index}") { index }
    end
  end
end

private class InvocationContextPlugin < CrystKit::Plugin::Base
  def identifier : String
    "invocation_context"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(identifier, commands: ["invocation_context.security"])
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command_context("invocation_context.security") do |invocation, _params|
      invocation.security == context.security
    end
  end
end

private class MetadataPolicyPlugin < CrystKit::Plugin::Base
  def identifier : String
    "metadata_policy"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      capabilities: %w(metadata_policy:read),
      commands: %w(metadata_policy.list),
      ipc: CrystKit::IPC::PolicyCatalog.new.read("metadata_policy.list", "metadata_policy:read"),
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    context.command("metadata_policy.list") { ["ok"] }
  end
end

describe CrystKit::Core::Runtime do
  it "is the sole owner of app runtime services and plugins" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      app.router.should be(app.runtime.router)
      app.security.should be(app.runtime.security)
      app.window_registry.should be(app.runtime.windows)
      app.plugins.should be(app.runtime.plugins)
      app.runtime.platform.window.should be_a(CrystKit::Platform::WindowBackend)

      plugin = CrystKit::Plugins::SystemInfo.new
      app.plugin(plugin)
      app.plugins.find?("system_info").should be(plugin)
    end
  end

  it "composes built-in plugins through the runtime-owned platform services" do
    SpecHelpers.with_temp_dir do |dir|
      dialog_provider = RuntimeDialogProvider.new
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.plugin(CrystKit::Plugins::Dialog.new(dialog_provider))

      result = app.router.invoke_command(
        "dialog.message",
        JSON.parse(%({"title":"Runtime","message":"composed","kind":"info"})),
      )

      result.as_bool.should be_true
      dialog_provider.messages.should eq(["composed"])
    end
  end

  it "exposes declarative plugin metadata through the runtime registry" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      plugin = CrystKit::Plugins::SystemInfo.new

      app.plugin(plugin)

      metadata = app.plugins.metadata("system_info")
      metadata.id.should eq("system_info")
      metadata.dependencies.should be_empty
    end
  end

  it "registers plugin command policy from metadata without command boilerplate" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      app.plugin(MetadataPolicyPlugin.new)

      policy = app.router.policy_resolver.resolve("metadata_policy.list")
      policy.capability.should eq("metadata_policy:read")
    end
  end

  it "grants plugin metadata capabilities when registering plugins" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      context = CrystKit::IPC::Context.new(app: app, security: app.security, frontend: true)

      app.plugin(MetadataPolicyPlugin.new)

      app.security.capabilities.check("metadata_policy:read").should be_true
      result = app.router.invoke_command("metadata_policy.list", JSON.parse("{}"), context)
      result.should eq(JSON::Any.new([JSON::Any.new("ok")]))
    end
  end

  it "allows built-in plugin frontend commands from plugin metadata grants" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      context = CrystKit::IPC::Context.new(app: app, security: app.security, frontend: true)

      app.plugin(CrystKit::Plugins::SystemInfo.new)

      app.security.capabilities.check("system:read").should be_true
      result = app.router.invoke_command("system_info.os", JSON.parse("{}"), context)
      result.as_h.has_key?("name").should be_true
    end
  end

  it "owns plugin commands under canonical dot-separated names only" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      app.plugin(OwnedCommandPlugin.new)

      app.plugins.command_owner("owned.ping").should eq("owned")
      app.router.registered_commands.should contain("owned.ping")
      app.router.registered_commands.should_not contain("owned:ping")
      expect_raises(CrystKit::Core::IPCError, /not registered/) do
        app.router.invoke_command("owned:ping", JSON.parse("{}"))
      end
      app.router.invoke_command("owned.ping", JSON.parse("{}")).should eq(JSON::Any.new("pong"))
      app.router.invoke_command("owned.echo", JSON.parse(%({"value":"named"}))).should eq(JSON::Any.new("named"))
      app.router.invoke_command("owned.join", JSON.parse(%(["field-","named"]))).should eq(JSON::Any.new("field-named"))
      app.router.invoke_command("owned.identity", JSON.parse("{}")).should eq(JSON::Any.new("owned"))
    end
  end

  it "preserves invocation context when routing plugin commands" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.plugin(InvocationContextPlugin.new)
      context = CrystKit::IPC::Context.new(app: app, security: app.security)

      result = app.router.invoke_command("invocation_context.security", JSON.parse(%({})), context)

      result.should eq(JSON::Any.new(true))
    end
  end

  it "returns a validation envelope for invalid struct-backed plugin requests" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.plugin(OwnedCommandPlugin.new)

      envelope = app.router.invoke_envelope("owned.echo", JSON.parse(%({"wrong":"field"})))

      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("VALIDATION_ERROR")
    end
  end

  it "returns a validation envelope for invalid field-backed plugin requests" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.plugin(OwnedCommandPlugin.new)

      envelope = app.router.invoke_envelope("owned.join", JSON.parse(%({"prefix":"missing suffix"})))

      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("VALIDATION_ERROR")
    end
  end

  it "removes plugin-owned commands during cleanup" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      app.plugin(OwnedCommandPlugin.new)

      app.plugins.cleanup_all

      app.router.registered_commands.should_not contain("owned.ping")
      expect_raises(CrystKit::Core::IPCError) do
        app.router.invoke_command("owned.ping", JSON.parse("{}"))
      end
    end
  end

  it "enforces runtime plugin command limits and rolls back partial routes" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      expect_raises(CrystKit::Core::PluginError, /maximum of 100 commands/) do
        app.plugin(TooManyCommandsPlugin.new)
      end

      app.plugins.find?("too_many").should be_nil
      app.router.registered_commands.none?(&.starts_with?("too_many.")).should be_true
    end
  end

  it "rejects runtime commands missing from declarative plugin metadata" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      expect_raises(CrystKit::Core::PluginError, /undeclared commands/) do
        app.plugin(UndeclaredCommandPlugin.new)
      end

      app.router.registered_commands.should_not contain("undeclared_command.ping")
    end
  end

  it "rejects plugin events missing from declarative plugin metadata" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))

      expect_raises(CrystKit::Core::PluginError, /undeclared event/) do
        app.plugin(UndeclaredEventPlugin.new)
      end
    end
  end
end
