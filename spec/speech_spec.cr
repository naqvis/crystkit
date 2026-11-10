require "./spec_helper"
require "../src/features/speech"
require "../src/plugins/builtins/speech"

describe CrystKit::Features::Voice do
  it "serializes to JSON" do
    v = CrystKit::Features::Voice.new(id: "v1", name: "V1", lang: "fr-FR", variant: "premium")
    json = v.to_json
    json.should contain("v1")
    json.should contain("fr-FR")
    json.should contain("premium")
  end
end

describe CrystKit::Features::SpeechSynthesizer do
  it "requires speech:synth capability for list_voices" do
    caps = CrystKit::Security::CapabilitySystem.new
    synth = CrystKit::Features::SpeechSynthesizer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /speech:synth/) do
      synth.list_voices
    end
  end

  it "requires speech:synth capability for speak" do
    caps = CrystKit::Security::CapabilitySystem.new
    synth = CrystKit::Features::SpeechSynthesizer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /speech:synth/) do
      synth.speak("hello")
    end
  end

  it "returns the backend voice list" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    voices = synth.list_voices
    voices.should eq(backend.voices)
    voices.should be_a(Array(CrystKit::Features::Voice))
  end

  it "speaking? returns false initially" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    synth.speaking?.should be_false
  end

  it "speak records text and flips speaking? state" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    synth.speak("hello")
    backend.spoken.should eq(["hello"])
    synth.speaking?.should be_true
  end

  it "forwards voice and tuning options unchanged" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    voice = backend.voices.last
    options = CrystKit::Features::SynthesisOptions.new(
      voice: voice,
      rate: 1.5,
      pitch: 0.8,
      volume: 0.4,
    )

    synth.speak("bonjour", options)

    received = backend.spoken_options.last
    received.voice.should eq(voice)
    received.rate.should eq(1.5)
    received.pitch.should eq(0.8)
    received.volume.should eq(0.4)
  end

  it "reflects natural completion reported by the backend" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    synth.speak("hello")
    backend.finish
    synth.speaking?.should be_false
  end

  it "stop, pause, resume drive the backend" do
    backend = CrystKit::Test::FakeSpeechSynthesizer.new
    synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
    synth.speak("hi")
    synth.pause
    backend.paused?.should be_true
    synth.resume
    backend.paused?.should be_false
    synth.stop
    backend.speaking?.should be_false
  end
end

describe CrystKit::Plugins::Speech do
  it "exposes the complete speech command surface" do
    metadata = CrystKit::Plugins::Speech.new.metadata
    metadata.commands.should contain("speech.speaking")
    metadata.commands.should contain("speech.recognize_languages")
    metadata.commands.should contain("speech.recognize_available")
    metadata.commands.should contain("speech.recognize_permission")
    metadata.commands.should contain("speech.recognize_request_permission")
    metadata.commands.should contain("speech.recognize_abort")
    metadata.commands.should contain("speech.recognize_listening")
    metadata.events.should contain("speech.recognition_result")
    metadata.events.should contain("speech.recognition_error")
    metadata.events.should contain("speech.recognition_end")
    metadata.ipc.commands["speech.recognize_available"].capability.should eq("speech:recognize")
    metadata.ipc.commands["speech.recognize_languages"].capability.should eq("speech:recognize")
  end

  it "bridges native recognition callbacks to frontend events" do
    SpecHelpers.with_fake_window_app do |app|
      native = CrystKit::Test::FakeSpeechRecognizer.new
      recognizer = CrystKit::Features::SpeechRecognizer.new(nil, native)
      synth = CrystKit::Features::SpeechSynthesizer.new(
        nil,
        CrystKit::Test::FakeSpeechSynthesizer.new
      )
      results = [] of JSON::Any
      errors = [] of JSON::Any
      ended = false
      app.router.subscribe_event("speech.recognition_result", ->(payload : JSON::Any) { results << payload })
      app.router.subscribe_event("speech.recognition_error", ->(payload : JSON::Any) { errors << payload })
      app.router.subscribe_event("speech.recognition_end", ->(_payload : JSON::Any) { ended = true })
      app.grant("speech:recognize")
      app.plugin(CrystKit::Plugins::Speech.new(synth, recognizer))

      native.emit_result("hello", false, 0.75)
      native.emit_error("microphone failed")
      native.emit_end

      results.first["transcript"].as_s.should eq("hello")
      results.first["final"].as_bool.should be_false
      results.first["confidence"].as_f.should eq(0.75)
      errors.first["message"].as_s.should eq("microphone failed")
      ended.should be_true
    end
  end

  it "resolves a voice and forwards every synthesis option through IPC" do
    SpecHelpers.with_fake_window_app do |app|
      backend = CrystKit::Test::FakeSpeechSynthesizer.new
      synth = CrystKit::Features::SpeechSynthesizer.new(nil, backend)
      recognizer = CrystKit::Features::SpeechRecognizer.new(
        nil,
        CrystKit::Test::FakeSpeechRecognizer.new
      )
      app.grant("speech:synth", "speech:recognize")
      app.plugin(CrystKit::Plugins::Speech.new(synth, recognizer))

      result = app.router.invoke_command(
        "speech.speak",
        JSON.parse(%(["bonjour", {"voice":"fr","rate":1.5,"pitch":0.8,"volume":0.4}]))
      )

      result["success"].as_bool.should be_true
      received = backend.spoken_options.last
      received.voice.not_nil!.id.should eq("fr")
      received.rate.should eq(1.5)
      received.pitch.should eq(0.8)
      received.volume.should eq(0.4)
    end
  end

  it "reports recognition availability through IPC" do
    SpecHelpers.with_fake_window_app do |app|
      synth = CrystKit::Features::SpeechSynthesizer.new(
        nil,
        CrystKit::Test::FakeSpeechSynthesizer.new
      )
      recognizer = CrystKit::Features::SpeechRecognizer.new(
        nil,
        CrystKit::Test::FakeSpeechRecognizer.new
      )
      app.grant("speech:recognize")
      app.plugin(CrystKit::Plugins::Speech.new(synth, recognizer))

      result = app.router.invoke_command("speech.recognize_available", JSON.parse("{}"))
      result["available"].as_bool.should be_true
    end
  end

  it "lists recognition languages through IPC" do
    SpecHelpers.with_fake_window_app do |app|
      synth = CrystKit::Features::SpeechSynthesizer.new(
        nil,
        CrystKit::Test::FakeSpeechSynthesizer.new
      )
      recognizer = CrystKit::Features::SpeechRecognizer.new(
        nil,
        CrystKit::Test::FakeSpeechRecognizer.new
      )
      app.grant("speech:recognize")
      app.plugin(CrystKit::Plugins::Speech.new(synth, recognizer))

      result = app.router.invoke_command("speech.recognize_languages", JSON.parse("{}"))
      result["languages"].as_a.map(&.as_s).should eq(%w(en-US fr-FR))
    end
  end

  it "rejects an unknown voice instead of silently using the default" do
    SpecHelpers.with_fake_window_app do |app|
      synth = CrystKit::Features::SpeechSynthesizer.new(
        nil,
        CrystKit::Test::FakeSpeechSynthesizer.new
      )
      app.grant("speech:synth")
      app.plugin(CrystKit::Plugins::Speech.new(synth))

      expect_raises(CrystKit::Core::IPCError, /unknown speech voice/) do
        app.router.invoke_command(
          "speech.speak",
          JSON.parse(%(["hello", {"voice":"missing"}]))
        )
      end
    end
  end
end

describe CrystKit::Features::SpeechRecognizer do
  it "returns the backend recognition languages" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    recog.languages.should eq(%w(en-US fr-FR))
  end

  it "requires speech:recognize capability for start" do
    caps = CrystKit::Security::CapabilitySystem.new
    recog = CrystKit::Features::SpeechRecognizer.new(caps)
    expect_raises(CrystKit::Core::SecurityError, /speech:recognize/) do
      recog.start
    end
  end

  it "listening? returns false initially" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    recog.listening?.should be_false
  end

  it "registers result handlers" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    results = [] of String
    recog.on_result { |text, _| results << text }
    recog.notify_result("hello", true)
    results.should eq(["hello"])
  end

  it "registers error handlers" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    errors = [] of String
    recog.on_error { |msg| errors << msg }
    recog.notify_error("network error")
    errors.should eq(["network error"])
  end

  it "handles multiple result handlers" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    calls = [] of String
    recog.on_result { |_, _| calls << "a" }
    recog.on_result { |_, _| calls << "b" }
    recog.notify_result("test", false)
    calls.should eq(["a", "b"])
  end

  it "drives an available native recognizer" do
    native = CrystKit::Test::FakeSpeechRecognizer.new
    recog = CrystKit::Features::SpeechRecognizer.new(nil, native)
    recog.start
    recog.listening?.should be_true
    recog.stop
    recog.listening?.should be_false
  end

  it "stop is safe to call" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    recog.stop
  end

  it "abort is safe to call" do
    recog = CrystKit::Features::SpeechRecognizer.new(nil, CrystKit::Test::FakeSpeechRecognizer.new)
    recog.abort
  end
end
