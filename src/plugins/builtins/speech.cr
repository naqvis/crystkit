require "../base"
require "../../features/speech"

module CrystKit
  module Plugins
    # Builtin plugin that exposes speech synthesis (text-to-speech) and
    # speech recognition (speech-to-text) to the frontend.
    #
    # Synthesis and recognition are governed by separate capabilities so an
    # application can grant text-to-speech without enabling microphone
    # access. Synthesis supports voice, rate, pitch, and volume controls;
    # recognition exposes native availability, lifecycle, and listening state.
    #
    # Registers IPC commands:
    #   speech:list_voices, speech:speak, speech:stop, speech:pause,
    #   speech:resume, speech:speaking, speech:recognize_languages,
    #   speech:recognize_available,
    #   speech:recognize_permission, speech:recognize_request_permission,
    #   speech:recognize_start, speech:recognize_stop, speech:recognize_abort,
    #   speech:recognize_listening
    #
    # Required capabilities: `speech:synth`, `speech:recognize`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Speech.new)
    # ```
    class Speech < Plugin::Base
      def initialize(@synthesizer : Features::SpeechSynthesizer? = nil,
                     @recognizer : Features::SpeechRecognizer? = nil)
      end

      # The speech-synthesis feature, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! synthesizer : Features::SpeechSynthesizer

      # The speech-recognition feature, lazily initialized during
      # `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! recognizer : Features::SpeechRecognizer

      # Returns the unique plugin identifier `"speech"`.
      def identifier : String
        "speech"
      end

      # Returns the metadata contract splitting speech access into synthesis
      # and recognition capabilities.
      #
      # The synthesis commands require `speech:synth`; recognition commands
      # require `speech:recognize`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(speech.list_voices speech.speak speech.stop speech.pause speech.resume speech.speaking), "speech:synth")
          .require(%w(speech.recognize_languages speech.recognize_available speech.recognize_permission speech.recognize_request_permission speech.recognize_start speech.recognize_stop speech.recognize_abort speech.recognize_listening), "speech:recognize")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(speech:synth speech:recognize),
          commands: %w(speech.list_voices speech.speak speech.stop speech.pause speech.resume speech.speaking speech.recognize_languages speech.recognize_available speech.recognize_permission speech.recognize_request_permission speech.recognize_start speech.recognize_stop speech.recognize_abort speech.recognize_listening),
          events: %w(speech.recognition_result speech.recognition_error speech.recognition_end),
          ipc: ipc,
        )
      end

      # Registers the IPC commands.
      #
      # `speech.list_voices` returns `{"voices" => [...]}` with each voice's
      # `id`, `name`, `lang`, `local` flag, and optional `variant`.
      # `speech.recognize_languages` returns `{"languages" => [...]}` with the
      # BCP 47 tags supported by the system recognizer.
      # `speech.speak` takes the text and a JSON options object with optional
      # `voice` (a voice identifier), `rate`, `pitch`, and `volume` (the
      # numeric fields each default to `1.0`). The control
      # commands (`stop`, `pause`, `resume`, `recognize_start`, `recognize_stop`) return
      # `{"success" => true}`. `recognize_start` takes a language code and a
      # boolean requesting interim results.
      def initialize_plugin(context : Plugin::Context) : Nil
        synth = @synthesizer || Features::SpeechSynthesizer.new(context.capabilities)
        recog = @recognizer || Features::SpeechRecognizer.new(context.capabilities)
        @synthesizer = synth
        @recognizer = recog

        recog.on_result_event do |result|
          context.emit("speech.recognition_result", context.app.coerce_to_json({
            "transcript" => result.transcript,
            "final"      => result.final?,
            "confidence" => result.confidence,
          }))
        end
        recog.on_error do |message|
          context.emit("speech.recognition_error", context.app.coerce_to_json({"message" => message}))
        end
        recog.on_end do
          context.emit("speech.recognition_end", JSON::Any.new({} of String => JSON::Any))
        end

        context.command "speech.list_voices" do
          {"voices" => synth.list_voices.map { |v|
            {"id" => v.id, "name" => v.name, "lang" => v.lang, "local" => v.local?, "variant" => v.variant}
          }}
        end

        context.command "speech.speak", String, JSON::Any do |text, opts_json|
          opts_obj = opts_json.as_h
          voice_id = opts_obj["voice"]?.try(&.as_s?) || opts_obj["voice_id"]?.try(&.as_s?)
          voice = nil
          if voice_id && !voice_id.empty?
            voice = synth.list_voices.find { |candidate| candidate.id == voice_id }
            raise ArgumentError.new("unknown speech voice: #{voice_id}") unless voice
          end
          options = Features::SynthesisOptions.new(
            voice: voice,
            rate: opts_obj["rate"]?.try(&.as_f) || 1.0,
            pitch: opts_obj["pitch"]?.try(&.as_f) || 1.0,
            volume: opts_obj["volume"]?.try(&.as_f) || 1.0,
          )
          synth.speak(text, options)
          {"success" => true}
        end

        context.command "speech.stop" do
          synth.stop
          {"success" => true}
        end

        context.command "speech.pause" do
          synth.pause
          {"success" => true}
        end

        context.command "speech.resume" do
          synth.resume
          {"success" => true}
        end

        context.command "speech.speaking" do
          {"speaking" => synth.speaking?}
        end

        context.command "speech.recognize_available" do
          {"available" => recog.available?}
        end

        context.command "speech.recognize_languages" do
          {"languages" => recog.languages}
        end

        context.command "speech.recognize_permission" do
          {"permission" => recog.permission.to_s.underscore}
        end

        context.command "speech.recognize_request_permission" do
          {"permission" => recog.request_permission.to_s.underscore}
        end

        context.command "speech.recognize_start", String, Bool do |lang, interim|
          recog.start(lang, interim)
          {"success" => true}
        end

        context.command "speech.recognize_stop" do
          recog.stop
          {"success" => true}
        end

        context.command "speech.recognize_abort" do
          recog.abort
          {"success" => true}
        end

        context.command "speech.recognize_listening" do
          {"listening" => recog.listening?}
        end
      end

      def cleanup_plugin : Nil
        @recognizer.try(&.cleanup)
        @synthesizer.try(&.cleanup)
      end
    end
  end
end
