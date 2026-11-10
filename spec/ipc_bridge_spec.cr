require "json"
require "../src/ipc/js_bridge"

module SpecIPC
  class BridgeHost
    include CrystKit::IPC::JSClientSetup
    getter initialized = [] of String
    getter evaluated = [] of String
    getter bindings = {} of String => Webview::JSProc
    getter async_bindings = {} of String => Proc(String, Array(JSON::Any), Nil)
    getter responses = {} of String => {Int32, String}
    @seq_channels = {} of String => Channel({Int32, String})

    def init(js : String) : Nil
      @initialized << js
    end

    def bind(name : String, handler : Webview::JSProc) : Nil
      @bindings[name] = handler
    end

    def bind_async(name : String, &block : String, Array(JSON::Any) -> Nil)
      @async_bindings[name] = block
    end

    def respond(seq : String, status : Int32, result_json : String)
      result = {status, result_json}
      @responses[seq] = result
      @seq_channels[seq]?.try(&.send(result))
    end

    def dispatch(&block : ->) : Nil
      block.call
    end

    def eval(js : String) : Nil
      @evaluated << js
    end

    protected def seq_channels
      @seq_channels
    end

    def transport_for(command : String) : String
      @initialized.each do |js|
        next unless js.starts_with?("window.__CRYSTKIT_IPC_TRANSPORTS__")
        eq_idx = js.index('=')
        semi_idx = js.rindex(';')
        next unless eq_idx && semi_idx && semi_idx > eq_idx
        json_str = js[(eq_idx + 1)...semi_idx].strip
        transports = JSON.parse(json_str).as_h
        return transports[command]?.try(&.as_s) || "async"
      end
      "async"
    end

    def clear_pending_seq
      @seq_channels.each_value(&.close)
      @seq_channels.clear
    end
  end

  private def self.payload_for(command : String, params : JSON::Any?) : String
    inner = params ? params.to_json : "null"
    %({"command":"#{command}","params":#{inner}})
  end

  def self.invoke_sync(host : BridgeHost, command : String, params : JSON::Any?) : CrystKit::IPC::ResponseEnvelope
    handler = host.bindings["__crystal_ipc_invoke_sync"]
    raw = handler.call([JSON::Any.new(payload_for(command, params))])
    CrystKit::IPC::ResponseEnvelope.from_json(raw.to_json)
  end

  def self.invoke_async(
    host : BridgeHost,
    command : String,
    params : JSON::Any?,
    timeout : Time::Span = 5.seconds,
  ) : CrystKit::IPC::ResponseEnvelope
    seq = "seq-#{command}-#{host.responses.size}"
    ch = Channel({Int32, String}).new(1)
    host.seq_channels[seq] = ch
    callback = host.async_bindings["__crystal_ipc_invoke"]
    callback.call(seq, [JSON::Any.new(payload_for(command, params))])
    select
    when result = ch.receive
      host.seq_channels.delete(seq)
      CrystKit::IPC::ResponseEnvelope.from_json(result[1])
    when timeout(timeout)
      host.seq_channels.delete(seq)
      raise "Timed out waiting for async IPC response to '#{command}' after #{timeout}"
    end
  end

  def self.invoke_via_bridge(host : BridgeHost, command : String, params : JSON::Any?) : CrystKit::IPC::ResponseEnvelope
    if host.transport_for(command) == "sync"
      invoke_sync(host, command, params)
    else
      invoke_async(host, command, params)
    end
  end
end
