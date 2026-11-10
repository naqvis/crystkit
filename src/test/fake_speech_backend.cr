require "../features/speech"

module CrystKit::Test
  class FakeSpeechSynthesizer < ::NativeDesktop::SpeechSynthesizer
    getter voices : Array(Features::Voice)
    getter spoken = [] of String
    getter spoken_options = [] of Features::SynthesisOptions
    getter? speaking = false
    getter? paused = false

    def initialize(@voices = [
                     Features::Voice.new(id: "en", name: "English", lang: "en-US", local: true),
                     Features::Voice.new(id: "fr", name: "Français", lang: "fr-FR", local: true),
                   ])
    end

    def speak(text : String, options : Features::SynthesisOptions = Features::SynthesisOptions.new) : Nil
      @spoken << text
      @spoken_options << options
      @speaking = true
      @paused = false
    end

    def stop : Nil
      @speaking = false
      @paused = false
    end

    def pause : Nil
      @paused = true
    end

    def resume : Nil
      @paused = false
    end

    def speaking? : Bool
      @speaking
    end

    def cleanup : Nil
      stop
    end

    def finish : Nil
      @speaking = false
      @paused = false
    end
  end

  class FakeSpeechRecognizer < ::NativeDesktop::SpeechRecognizer
    getter? listening = false

    def languages : Array(String)
      %w(en-US fr-FR)
    end

    def available?(language : String = "en-US") : Bool
      true
    end

    def permission : ::NativeDesktop::SpeechRecognitionPermission
      ::NativeDesktop::SpeechRecognitionPermission::Granted
    end

    def request_permission : ::NativeDesktop::SpeechRecognitionPermission
      permission
    end

    def start(language : String = "en-US", interim : Bool = true) : Nil
      @listening = true
    end

    def stop : Nil
      @listening = false
    end

    def abort : Nil
      @listening = false
    end

    def emit_result(text : String, final : Bool = true, confidence : Float64? = nil) : Nil
      @result_handlers.each(&.call(::NativeDesktop::RecognitionResult.new(text, final, confidence)))
    end

    def emit_error(message : String) : Nil
      error = ::NativeDesktop::Error.new(message, :speech_recognition_failed)
      @error_handlers.each(&.call(error))
    end

    def emit_end : Nil
      @end_handlers.each(&.call)
    end
  end
end
