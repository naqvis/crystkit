require "./spec_helper"
require "../src/ipc/channel"
require "../src/ipc/router"

describe CrystKit::IPC::Channel do
  describe "#initialize" do
    it "generates unique IDs for different channels" do
      ipc = CrystKit::IPC::Router.new
      ch1 = CrystKit::IPC::Channel(String).new(ipc)
      ch2 = CrystKit::IPC::Channel(String).new(ipc)
      ch1.id.should_not eq(ch2.id)
    end
  end

  describe "#send" do
    it "emits a channel_data event with the value" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      received = [] of JSON::Any

      ipc.subscribe_event("__channel_data:#{ch.id}", ->(payload : JSON::Any) {
        received << payload
      })

      ch.send("hello")
      ch.send("world")

      received.size.should eq(2)
      received[0]["value"].as_s.should eq("hello") if received[0]["value"]?
      received[1]["value"].as_s.should eq("world") if received[1]["value"]?
    end

    it "includes sequence numbers in order" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      seqs = [] of Int64

      ipc.subscribe_event("__channel_data:#{ch.id}", ->(payload : JSON::Any) {
        seqs << payload["seq"].as_i64 if payload["seq"]?
      })

      ch.send("a")
      ch.send("b")
      ch.send("c")

      seqs.should eq([1_i64, 2_i64, 3_i64])
    end

    it "raises error when channel is closed" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.close

      expect_raises(CrystKit::Core::IPCError, /closed/) do
        ch.send("fail")
      end
    end

    it "includes the channel_id in the payload" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      received = [] of JSON::Any

      ipc.subscribe_event("__channel_data:#{ch.id}", ->(payload : JSON::Any) {
        received << payload
      })

      ch.send("test")

      received[0]["channel_id"].as_s.should eq(ch.id) if received[0]?
    end

    it "handles multiple channels independently" do
      ipc = CrystKit::IPC::Router.new
      ch1 = CrystKit::IPC::Channel(String).new(ipc)
      ch2 = CrystKit::IPC::Channel(String).new(ipc)
      received1 = [] of JSON::Any
      received2 = [] of JSON::Any

      ipc.subscribe_event("__channel_data:#{ch1.id}", ->(payload : JSON::Any) {
        received1 << payload
      })
      ipc.subscribe_event("__channel_data:#{ch2.id}", ->(payload : JSON::Any) {
        received2 << payload
      })

      ch1.send("from1")
      ch2.send("from2")

      received1.size.should eq(1)
      received2.size.should eq(1)
    end

    it "allows an event callback to close the channel without deadlocking" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ipc.subscribe_event("__channel_data:#{ch.id}", ->(_payload : JSON::Any) { ch.close })

      ch.send("last")
      ch.closed?.should be_true
    end
  end

  describe "#close" do
    it "marks the channel as closed" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.closed?.should be_false
      ch.close
      ch.closed?.should be_true
    end

    it "emits a channel_close event" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      received = false

      ipc.subscribe_event("__channel_close:#{ch.id}", ->(_payload : JSON::Any) {
        received = true
      })

      ch.close
      received.should be_true
    end

    it "is idempotent (calling close multiple times is safe)" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.close
      ch.close
      ch.closed?.should be_true
    end
  end

  describe "#close_with_error" do
    it "emits a channel_error event with the error message" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      received = nil

      ipc.subscribe_event("__channel_error:#{ch.id}", ->(payload : JSON::Any) {
        received = payload["error"]?.try(&.as_s)
      })

      ch.close_with_error("something broke")
      received.should eq("something broke")
    end

    it "marks the channel as closed" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.close_with_error("err")
      ch.closed?.should be_true
    end
  end

  describe "#active?" do
    it "returns false when no values have been sent" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.active?.should be_false
    end

    it "returns true after values have been sent" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.send("test")
      ch.active?.should be_true
    end

    it "returns false after close" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc)
      ch.send("test")
      ch.close
      ch.active?.should be_false
    end
  end

  describe "frontend subscription authorization" do
    it "denies unknown frontend channel subscription" do
      ipc = CrystKit::IPC::Router.new

      expect_raises(CrystKit::Core::SecurityError, /Unknown IPC channel/) do
        ipc.authorize_frontend_channel!("missing", CrystKit::IPC::Context.new(frontend: true))
      end
    end

    it "allows subscription to a known frontend channel" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc, owner: "notes.list")

      ipc.authorize_frontend_channel!(ch.id, CrystKit::IPC::Context.new(frontend: true))
    end

    it "denies subscription when the channel is scoped to a different window" do
      ipc = CrystKit::IPC::Router.new
      ch = CrystKit::IPC::Channel(String).new(ipc, owner: "notes.list", target_window_id: "main")

      expect_raises(CrystKit::Core::SecurityError, /not available to this window/) do
        ipc.authorize_frontend_channel!(ch.id, CrystKit::IPC::Context.new(frontend: true))
      end
    end
  end
end
