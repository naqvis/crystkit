require "./spec_helper"
require "../src/features/single_instance"

private class SingleInstanceSpecProvider < CrystKit::Features::SingleInstance::Provider
  property acquire_result = true
  property acquire_error : Exception?
  property release_error : Exception?
  property connect_error : Exception?
  getter acquire_calls = 0
  getter release_calls = 0
  getter cleanup_calls = 0
  getter sent_payloads = [] of String
  getter path : Path = Path[Dir.tempdir] / "crystkit-single-instance-provider.lock"
  @handler : Proc(String, Nil)?

  def acquire : Bool
    @acquire_calls += 1
    if error = @acquire_error
      raise error
    end
    @acquire_result
  end

  def release : Nil
    @release_calls += 1
    if error = @release_error
      raise error
    end
  end

  def cleanup_stale : Bool
    @cleanup_calls += 1
    false
  end

  def start_ipc_server(&handler : String ->) : Nil
    @handler = handler
  end

  def connect_to_primary(payload : String) : Nil
    if error = @connect_error
      raise error
    end
    @sent_payloads << payload
    @handler.try(&.call(payload))
  end

  def deliver(payload : String) : Nil
    @handler.try(&.call(payload))
  end
end

describe CrystKit::Features::SingleInstance do
  it "acquires and releases through its provider" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    instance.acquired?.should be_false
    instance.acquire.should be_true
    instance.acquired?.should be_true
    provider.cleanup_calls.should eq(1)
    provider.acquire_calls.should eq(1)

    instance.release
    instance.acquired?.should be_false
    provider.release_calls.should eq(1)
  end

  it "preserves a failed acquisition result" do
    provider = SingleInstanceSpecProvider.new
    provider.acquire_result = false
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    instance.acquire.should be_false
    instance.acquired?.should be_false
  end

  it "wraps acquisition errors" do
    provider = SingleInstanceSpecProvider.new
    provider.acquire_error = IO::Error.new("lock failed")
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    error = expect_raises(CrystKit::Core::Error) { instance.acquire }
    error.code.should eq("LOCK_ACQUIRE_FAILED")
    error.message.to_s.should contain("com.example.app")
    error.message.to_s.should contain("lock failed")
  end

  it "bypasses locking in multi-instance mode" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", multi_instance: true, provider: provider)

    instance.acquire.should be_true
    provider.cleanup_calls.should eq(0)
    provider.acquire_calls.should eq(0)
  end

  it "serializes arguments before sending them to the provider" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    instance.send_to_existing(["--open", "file name.txt"])

    provider.sent_payloads.should eq([%(["--open","file name.txt"])])
  end

  it "rejects oversized payloads before calling the provider" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)
    oversized = "x" * (CrystKit::Features::SingleInstance::MAX_PAYLOAD_SIZE + 1)

    error = expect_raises(CrystKit::Core::Error) { instance.send_to_existing([oversized]) }
    error.code.should eq("PAYLOAD_TOO_LARGE")
    provider.sent_payloads.should be_empty
  end

  it "wraps provider send failures" do
    provider = SingleInstanceSpecProvider.new
    provider.connect_error = IO::Error.new("connection failed")
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    error = expect_raises(CrystKit::Core::Error) { instance.send_to_existing(["--open"]) }
    error.code.should eq("IPC_SEND_FAILED")
    error.message.to_s.should contain("connection failed")
  end

  it "starts listening only after acquiring the primary lock" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)
    received = [] of Array(String)
    instance.on_receive { |args| received << args }

    instance.listen_for_args
    provider.deliver(%(["ignored"]))
    received.should be_empty

    instance.acquire
    instance.listen_for_args
    provider.deliver(%(["accepted"]))
    received.should eq([["accepted"]])
  end

  it "dispatches foreground, router, and receive handlers in order" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)
    router = CrystKit::IPC::Router.new
    calls = [] of String

    router.subscribe_event(
      CrystKit::Features::SingleInstance::SECOND_INSTANCE_EVENT,
      ->(_payload : JSON::Any) { calls << "router" },
    )
    instance.attach_router(router)
    instance.on_foreground { calls << "foreground" }
    instance.on_receive { |args| calls << "receive:#{args.first}" }

    instance.acquire
    instance.listen_for_args
    provider.deliver(%(["document.pdf"]))

    calls.should eq(["foreground", "router", "receive:document.pdf"])
  end

  it "isolates callback failures" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)
    called = false

    instance.on_foreground { raise "foreground failed" }
    instance.on_receive { |_| raise "first receive failed" }
    instance.on_receive { |_| called = true }
    instance.acquire
    instance.listen_for_args

    provider.deliver(%(["document.pdf"]))
    called.should be_true
  end

  it "ignores malformed provider payloads" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)
    called = false
    instance.on_receive { |_| called = true }
    instance.acquire
    instance.listen_for_args

    provider.deliver("not-json")
    called.should be_false
  end

  it "exposes the provider lock path" do
    provider = SingleInstanceSpecProvider.new
    instance = CrystKit::Features::SingleInstance.new("com.example.app", provider: provider)

    instance.lock_file_path.should eq(provider.path)
  end

  it "derives stable, distinct IPC endpoints from application identifiers" do
    first = CrystKit::Features::SingleInstance.new("com.example.first", provider: SingleInstanceSpecProvider.new)
    first_again = CrystKit::Features::SingleInstance.new("com.example.first", provider: SingleInstanceSpecProvider.new)
    second = CrystKit::Features::SingleInstance.new("com.example.second", provider: SingleInstanceSpecProvider.new)

    first.socket_path.should eq(first_again.socket_path)
    first.socket_path.should_not eq(second.socket_path)
    port = first.socket_path.split(':').last.to_i
    port.should be >= 49_152
    port.should be <= 65_535
  end
end
