require "./spec_helper"
require "./ipc_bridge_spec"
require "../src/ipc/router"
require "../src/ipc/js_bridge"

private def invoke_async(host : SpecIPC::BridgeHost, command : String, params : JSON::Any?)
  SpecIPC.invoke_async(host, command, params)
end

private def invoke_sync(host : SpecIPC::BridgeHost, command : String, params : JSON::Any?)
  SpecIPC.invoke_sync(host, command, params)
end

struct RouterEchoRequest
  include JSON::Serializable
  getter text : String
end

struct RouterAddRequest
  include JSON::Serializable
  getter left : Int32
  getter right : Int32
end

describe CrystKit::IPC::ResponseEnvelope do
  it "serializes a successful value" do
    envelope = CrystKit::IPC::ResponseEnvelope.success(JSON::Any.new("ok"))
    envelope.ok?.should be_true
    envelope.value.not_nil!.as_s.should eq("ok")
    envelope.error.should be_nil
    JSON.parse(envelope.to_json)["ok"].as_bool.should be_true
  end
  it "serializes a structured error" do
    envelope = CrystKit::IPC::ResponseEnvelope.failure(
      code: "COMMAND_NOT_FOUND",
      message: "Command missing",
      details: {"command" => JSON::Any.new("missing")}
    )
    envelope.ok?.should be_false
    envelope.value.should be_nil
    envelope.error.not_nil!.code.should eq("COMMAND_NOT_FOUND")
    JSON.parse(envelope.to_json)["error"]["details"]["command"].as_s.should eq("missing")
  end
end
describe CrystKit::IPC::Router do
  it "supports concurrent command registration and lookup" do
    router = CrystKit::IPC::Router.new
    finished = Channel(Bool).new(100)
    100.times do |index|
      spawn do
        name = "concurrent.command_#{index}"
        router.command(name) { |_params| JSON::Any.new(index) }
        router.command_info?(name).should_not be_nil
        finished.send(true)
      end
    end
    100.times { finished.receive }
    router.registered_commands.size.should eq(100)
    router.command_transports.size.should eq(100)
  end

  it "delivers from a snapshot when a listener unsubscribes itself" do
    router = CrystKit::IPC::Router.new
    calls = [] of String
    first_id = 0_u64
    first_id = router.subscribe_event("snapshot", ->(_payload : JSON::Any) {
      calls << "first"
      router.unsubscribe_event(first_id)
    })
    router.subscribe_event("snapshot", ->(_payload : JSON::Any) { calls << "second" })

    router.emit_event("snapshot", JSON::Any.new(nil))
    router.emit_event("snapshot", JSON::Any.new(nil))
    calls.should eq(["first", "second", "second"])
  end

  it "registers and invokes a JSON command through the Core API" do
    router = CrystKit::IPC::Router.new
    router.command("math.double") do |params|
      JSON::Any.new(params["value"].as_i * 2)
    end
    result = router.invoke_command("math.double", JSON.parse(%({"value": 4})))
    result.as_i.should eq(8)
    router.registered_commands.should contain("math.double")
  end
  it "rejects colon-separated command names" do
    router = CrystKit::IPC::Router.new
    expect_raises(CrystKit::Core::IPCError, /dot-separated/) do
      router.command("math:double") { |_params| JSON::Any.new(2) }
    end
  end
  it "returns a success envelope for frontend invoke" do
    router = CrystKit::IPC::Router.new
    router.command("hello") { |_params| JSON::Any.new("world") }
    envelope = router.invoke_envelope("hello", JSON.parse(%({})))
    envelope.ok?.should be_true
    envelope.value.not_nil!.as_s.should eq("world")
  end
  it "returns a structured error envelope for missing commands" do
    router = CrystKit::IPC::Router.new
    envelope = router.invoke_envelope("missing", JSON.parse(%({})))
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("COMMAND_NOT_FOUND")
  end
  it "decodes a complete JSON value into a Crystal type" do
    input = CrystKit::IPC::Router.decode(JSON.parse(%({"text": "hello"})), RouterEchoRequest)
    input.text.should eq("hello")
  end
  it "raises a validation error when Crystal type decoding fails" do
    error = expect_raises(CrystKit::Core::IPCError) do
      CrystKit::IPC::Router.decode(JSON.parse(%({"left": 1})), RouterAddRequest)
    end
    error.code.should eq("VALIDATION_ERROR")
  end
  it "passes command-scoped context to contextual handlers" do
    router = CrystKit::IPC::Router.new
    router.command_context("plugin.identity") do |context, _params|
      JSON::Any.new(context.plugin_id || "none")
    end
    result = router.invoke_command(
      "plugin.identity",
      JSON.parse(%({})),
      CrystKit::IPC::Context.new(plugin_id: "example"),
    )
    result.as_s.should eq("example")
  end
  it "allows app commands without explicit policy instead of guessing capabilities from names" do
    router = CrystKit::IPC::Router.new
    called = false
    router.command("notes.list") do |_params|
      called = true
      JSON::Any.new([JSON::Any.new("a")])
    end
    result = router.invoke_command(
      "notes.list",
      JSON.parse(%({})),
      CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new, frontend: true),
    )
    result.as_a.size.should eq(1)
    called.should be_true
  end
  it "denies missing explicit command policy capability before handler side effects" do
    router = CrystKit::IPC::Router.new
    called = false
    router.policy_resolver.register_override("notes.delete", CrystKit::IPC::CommandPolicy.new(capability: "notes:delete"))
    router.command("notes.delete") do |_params|
      called = true
      JSON::Any.new("deleted")
    end
    envelope = router.invoke_envelope(
      "notes.delete",
      JSON.parse(%({"id":1})),
      CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new, frontend: true),
    )
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
    called.should be_false
  end
  it "allows ambiguous app command names unless explicit policy is configured" do
    router = CrystKit::IPC::Router.new
    called = false
    router.command("notes.sync_everything") do |_params|
      called = true
      JSON::Any.new("synced")
    end
    envelope = router.invoke_envelope(
      "notes.sync_everything",
      JSON.parse(%({})),
      CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new, frontend: true),
    )
    envelope.ok?.should be_true
    envelope.value.not_nil!.as_s.should eq("synced")
    called.should be_true
  end
  it "denies a capability omitted from the invoking window entry" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("notes:read")
    caps.grant("notes:delete")
    caps.grant_to_window("notes:read", "preview")
    security = CrystKit::Security::Context.new(capabilities: caps, window_id: "preview")
    router = CrystKit::IPC::Router.new
    called = false
    router.policy_resolver.register_override("notes.delete", CrystKit::IPC::CommandPolicy.new(capability: "notes:delete"))
    router.command("notes.delete") do |_params|
      called = true
      JSON::Any.new("deleted")
    end
    envelope = router.invoke_envelope(
      "notes.delete",
      JSON.parse(%({"id":1})),
      CrystKit::IPC::Context.new(security: security, frontend: true),
    )
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
    called.should be_false
  end
  it "denies privileged IPC from unlisted windows when window grants are present" do
    caps = CrystKit::Security::CapabilitySystem.new
    caps.grant("notes:read")
    caps.grant_to_window("notes:read", "main")
    security = CrystKit::Security::Context.new(capabilities: caps, window_id: "unlisted")
    router = CrystKit::IPC::Router.new
    called = false
    router.policy_resolver.register_override("notes.list", CrystKit::IPC::CommandPolicy.new(capability: "notes:read"))
    router.command("notes.list") do |_params|
      called = true
      JSON::Any.new([JSON::Any.new("a")])
    end
    envelope = router.invoke_envelope(
      "notes.list",
      JSON.parse(%({})),
      CrystKit::IPC::Context.new(security: security, frontend: true),
    )
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
    called.should be_false
  end
  it "denies frontend event names that are not declared" do
    router = CrystKit::IPC::Router.new
    received = false
    router.subscribe_event("private.changed", ->(_payload : JSON::Any) { received = true })
    expect_raises(CrystKit::Core::SecurityError, /not declared as frontend-emittable/) do
      router.emit_frontend_event("private.changed", JSON.parse(%({})), CrystKit::IPC::Context.new(frontend: true))
    end
    received.should be_false
  end
  it "allows declared frontend events" do
    router = CrystKit::IPC::Router.new
    payloads = [] of JSON::Any
    router.declare_frontend_event("editor.changed")
    router.subscribe_event("editor.changed", ->(payload : JSON::Any) { payloads << payload })
    router.emit_frontend_event("editor.changed", JSON.parse(%({"dirty":true})), CrystKit::IPC::Context.new(frontend: true))
    payloads.should eq([JSON.parse(%({"dirty":true}))])
  end
end
describe "CrystKit::IPC::IPC_JS_CLIENT" do
  it "exposes the framework version on the frontend bridge" do
    CrystKit::IPC::IPC_JS_CLIENT.should contain("version:")
    CrystKit::IPC::IPC_JS_CLIENT.should contain(CrystKit::VERSION)
    CrystKit::IPC::IPC_JS_CLIENT.should contain("window.CrystKit = window.__CRYSTKIT_IPC__")
  end
  it "makes frontend emits return parsed IPC envelopes" do
    CrystKit::IPC::IPC_JS_CLIENT.should contain("emit: function(event, payload)")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("return window.__crystal_ipc_emit")
    CrystKit::IPC::IPC_JS_CLIENT.should contain("return handleEnvelope(raw, 'IPC emit failed')")
  end
  it "routes frontend invokes and emits through the router bindings" do
    router = CrystKit::IPC::Router.new
    router.command("greet") { |params| JSON::Any.new("Hello, #{params.as_s}") }
    received = [] of JSON::Any
    router.declare_frontend_event("frontend.ready")
    router.subscribe_event("frontend.ready", ->(payload : JSON::Any) { received << payload })
    host = SpecIPC::BridgeHost.new
    host.setup_ipc_client(router)
    envelope = invoke_sync(host, "greet", JSON::Any.new("Crystal"))
    envelope.ok?.should be_true
    envelope.value.should eq(JSON::Any.new("Hello, Crystal"))
    host.bindings["__crystal_ipc_emit"].call([
      JSON::Any.new(%({"event":"frontend.ready","payload":{"loaded":true}})),
    ])
    received.should eq([JSON.parse(%({"loaded":true}))])
  end
  it "passes the webview invocation context through frontend commands" do
    router = CrystKit::IPC::Router.new
    security = CrystKit::Security::Context.new
    router.command_context("context.security") do |context, _params|
      JSON::Any.new(context.security == security)
    end
    host = SpecIPC::BridgeHost.new
    host.setup_ipc_client(router, CrystKit::IPC::Context.new(security: security))
    envelope = invoke_sync(host, "context.security", nil)
    envelope.value.should eq(JSON::Any.new(true))
  end
  it "marks bridge invokes as frontend so policy is enforced before handlers" do
    router = CrystKit::IPC::Router.new
    called = false
    router.policy_resolver.register_override("notes.delete", CrystKit::IPC::CommandPolicy.new(capability: "notes:delete"))
    router.command("notes.delete") do |_params|
      called = true
      JSON::Any.new("deleted")
    end
    host = SpecIPC::BridgeHost.new
    host.setup_ipc_client(router, CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new))
    envelope = invoke_async(host, "notes.delete", JSON::Any.new({"id" => JSON::Any.new(1)}))
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
    called.should be_false
  end
  it "returns the structured response envelope when a frontend request is malformed" do
    host = SpecIPC::BridgeHost.new
    host.setup_ipc_client(CrystKit::IPC::Router.new)
    callback = host.async_bindings["__crystal_ipc_invoke"]
    callback.call("seq-malformed", [JSON::Any.new(%({"params":null}))])
    sleep 100.milliseconds
    _, json = host.responses["seq-malformed"]
    envelope = CrystKit::IPC::ResponseEnvelope.from_json(json)
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("INVALID_REQUEST")
  end
  it "returns the structured response envelope when a frontend emit is rejected" do
    host = SpecIPC::BridgeHost.new
    host.setup_ipc_client(CrystKit::IPC::Router.new)
    result = host.bindings["__crystal_ipc_emit"].call([
      JSON::Any.new(%({"event":"frontend:ping","payload":{"message":"ping"}})),
    ])
    envelope = CrystKit::IPC::ResponseEnvelope.from_json(result.to_json)
    envelope.ok?.should be_false
    envelope.error.not_nil!.code.should eq("IPC_POLICY_MISSING")
  end
  it "dispatches backend events to frontend listeners through the bridge" do
    host = SpecIPC::BridgeHost.new
    host.emit_to_frontend("window.focused", JSON.parse(%({"label":"main"})))
    host.evaluated.size.should eq(1)
    js = host.evaluated.last
    js.should match(/_dispatchEvent\(/)
    args_match = js.match(/_dispatchEvent\((.+),\s*(.+)\);/)
    args_match.should_not be_nil
    event_arg = JSON.parse(args_match.not_nil![1])
    payload_arg = JSON.parse(args_match.not_nil![2])
    event_arg.as_s.should eq("window.focused")
    payload_arg.as_h["label"].as_s.should eq("main")
  end
  it "skips emit_to_frontend after the bridge is marked dead" do
    host = SpecIPC::BridgeHost.new
    host.mark_dead!
    host.emit_to_frontend("window.focused", JSON.parse(%({"label":"main"})))
    host.evaluated.should be_empty
  end
  it "unwraps successful envelopes and preserves structured errors" do
    client = CrystKit::IPC::IPC_JS_CLIENT
    client.should contain("parsed.ok === true")
    client.should contain("return parsed.value")
    client.should contain("err.code = parsed.error.code")
    client.should contain("err.details = parsed.error.details")
    client.should_not contain("new Error(parsed.error)")
  end
end
describe "Async IPC commands" do
  describe CrystKit::IPC::Router do
    it "registers an async command and executes it successfully" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, params, _token| params }
      router.register_async_command("slow.echo", handler)
      info = router.command_info?("slow.echo").not_nil!
      info.async?.should be_true
      envelope = router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new("hello"))
      envelope.ok?.should be_true
      envelope.value.should eq(JSON::Any.new("hello"))
    end
    it "returns a TIMEOUT envelope when the handler exceeds its timeout" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, _token|
        sleep 2.seconds
        JSON::Any.new("done")
      }
      router.register_async_command("slow.blocked", handler, timeout: 100.milliseconds)
      info = router.command_info?("slow.blocked").not_nil!
      envelope = router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("TIMEOUT")
    end
    it "cancels the token when the timeout fires" do
      router = CrystKit::IPC::Router.new
      token_seen = [] of Bool
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, token|
        sleep 200.milliseconds
        token_seen << token.cancelled?
        JSON::Any.new("done")
      }
      router.register_async_command("slow.check", handler, timeout: 50.milliseconds)
      info = router.command_info?("slow.check").not_nil!
      router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new(nil))
      sleep 300.milliseconds
      token_seen.should eq([true])
    end
    it "wraps handler exceptions as failure envelopes" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, _token|
        raise CrystKit::Core::IPCError.new("boom", code: "BOOM")
      }
      router.register_async_command("fail.async", handler)
      info = router.command_info?("fail.async").not_nil!
      envelope = router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("BOOM")
    end
    it "wraps unexpected exceptions as INTERNAL_ERROR envelopes" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, _token|
        raise "unexpected"
      }
      router.register_async_command("fail.unexpected", handler)
      info = router.command_info?("fail.unexpected").not_nil!
      envelope = router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("COMMAND_EXECUTION_ERROR")
    end
    it "rejects duplicate async command names" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _p, _t| JSON::Any.new(nil) }
      router.register_async_command("dup", handler)
      expect_raises(CrystKit::Core::IPCError, "already registered") do
        router.register_async_command("dup", handler)
      end
    end
    it "rejects empty and colon-separated async command names" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _p, _t| JSON::Any.new(nil) }
      expect_raises(CrystKit::Core::IPCError, "cannot be empty") do
        router.register_async_command("", handler)
      end
      expect_raises(CrystKit::Core::IPCError, "dot-separated") do
        router.register_async_command("bad:name", handler)
      end
    end
    it "passes the cancellation token to the handler" do
      router = CrystKit::IPC::Router.new
      received_token = [] of CrystKit::Core::CancellationToken
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, token|
        received_token << token
        JSON::Any.new(token.cancelled?.to_s)
      }
      router.register_async_command("token.inspect", handler)
      info = router.command_info?("token.inspect").not_nil!
      envelope = router.execute_async(info, CrystKit::IPC::Context.new, JSON::Any.new(nil))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("false")
      received_token.size.should eq(1)
      received_token.first.cancelled?.should be_false
    end
  end
  describe "async dispatch through the JS bridge" do
    it "delivers async command results via respond" do
      router = CrystKit::IPC::Router.new
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, params, _token|
        JSON::Any.new("Hello, #{params.as_s}!")
      }
      router.register_async_command("async.greet", handler)
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(router)
      envelope = invoke_async(host, "async.greet", JSON::Any.new("Crystal"))
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("Hello, Crystal!")
    end
    it "delivers sync command results via the sync bind (no spawn, no respond)" do
      router = CrystKit::IPC::Router.new
      router.command("sync.greet") { |params| JSON::Any.new("Hi, #{params.as_s}") }
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(router)
      host.bindings.has_key?("__crystal_ipc_invoke_sync").should be_true
      handler = host.bindings["__crystal_ipc_invoke_sync"]
      raw = handler.call([JSON::Any.new(%({"command":"sync.greet","params":"World"}))])
      envelope = CrystKit::IPC::ResponseEnvelope.from_json(raw.to_json)
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("Hi, World")
      host.responses.should be_empty
    end
    it "routes sync commands through __crystal_ipc_invoke_sync (no spawn)" do
      router = CrystKit::IPC::Router.new
      router.command("sync.no.spawn") { |params| JSON::Any.new("ok:#{params.as_s}") }
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(router)
      host.bindings.has_key?("__crystal_ipc_invoke_sync").should be_true
      host.async_bindings.has_key?("__crystal_ipc_invoke").should be_true
      handler = host.bindings["__crystal_ipc_invoke_sync"]
      raw = handler.call([JSON::Any.new(%({"command":"sync.no.spawn","params":"hi"}))])
      envelope = CrystKit::IPC::ResponseEnvelope.from_json(raw.to_json)
      envelope.ok?.should be_true
      envelope.value.not_nil!.as_s.should eq("ok:hi")
    end
    it "enforces policy on async commands before handler execution" do
      router = CrystKit::IPC::Router.new
      called = false
      router.policy_resolver.register_override(
        "async.secure",
        CrystKit::IPC::CommandPolicy.new(capability: "secret"),
      )
      handler = CrystKit::IPC::AsyncContextualCommandHandler.new { |_ctx, _params, _token|
        called = true
        JSON::Any.new("done")
      }
      router.register_async_command("async.secure", handler)
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(router, CrystKit::IPC::Context.new(security: CrystKit::Security::Context.new))
      envelope = invoke_async(host, "async.secure", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("CAPABILITY_DENIED")
      called.should be_false
    end
    it "returns COMMAND_NOT_FOUND for unregistered async invocations" do
      router = CrystKit::IPC::Router.new
      host = SpecIPC::BridgeHost.new
      host.setup_ipc_client(router)
      envelope = invoke_async(host, "nope.nope", JSON::Any.new(nil))
      envelope.ok?.should be_false
      envelope.error.not_nil!.code.should eq("COMMAND_NOT_FOUND")
    end
  end
end
describe CrystKit::Core::CancellationToken do
  it "starts in a non-cancelled state" do
    token = CrystKit::Core::CancellationToken.new
    token.cancelled?.should be_false
  end
  it "transitions to cancelled after #cancel" do
    token = CrystKit::Core::CancellationToken.new
    token.cancel
    token.cancelled?.should be_true
  end
  it "#cancel is idempotent" do
    token = CrystKit::Core::CancellationToken.new
    token.cancel
    token.cancel
    token.cancelled?.should be_true
  end
  it "#check! raises CancelledError when cancelled" do
    token = CrystKit::Core::CancellationToken.new
    token.cancel
    expect_raises(CrystKit::Core::CancelledError) do
      token.check!
    end
  end
  it "#check! is a no-op when not cancelled" do
    token = CrystKit::Core::CancellationToken.new
    token.check!
  end
end
