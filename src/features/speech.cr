require "json"
require "log"
require "native_desktop"
require "../security/capability"

module CrystKit::Features
  alias Voice = ::NativeDesktop::Voice
  alias SynthesisOptions = ::NativeDesktop::SynthesisOptions
  alias RecognitionResult = ::NativeDesktop::RecognitionResult
  alias SpeechRecognitionPermission = ::NativeDesktop::SpeechRecognitionPermission

  # Text-to-speech synthesis guarded by CrystKit's capability system.
  class SpeechSynthesizer
    def initialize(@capabilities : Security::CapabilitySystem? = nil,
                   @native : ::NativeDesktop::SpeechSynthesizer = ::NativeDesktop.speech)
    end

    def list_voices : Array(Voice)
      @capabilities.try(&.require!("speech:synth"))
      @native.voices
    end

    def speak(text : String, options : SynthesisOptions = SynthesisOptions.new) : Nil
      @capabilities.try(&.require!("speech:synth"))
      @native.speak(text, options)
    end

    def stop : Nil
      @native.stop
    end

    def pause : Nil
      @native.pause
    end

    def resume : Nil
      @native.resume
    end

    def speaking? : Bool
      @native.speaking?
    end

    def cleanup : Nil
      @native.cleanup
    end
  end

  # Speech-recognition adapter backed by the host operating system.
  class SpeechRecognizer
    Log = ::Log.for(self)

    @result_handlers = [] of Proc(RecognitionResult, Nil)
    @error_handlers = [] of Proc(String, Nil)
    @end_handlers = [] of Proc(Nil)

    def initialize(@capabilities : Security::CapabilitySystem? = nil,
                   @native : ::NativeDesktop::SpeechRecognizer = ::NativeDesktop.speech_recognizer)
      @native.on_result { |result| notify_result(result) }
      @native.on_error { |error| notify_error(error.message || error.code.to_s) }
      @native.on_end { notify_end }
    end

    def available?(lang : String = "en-US") : Bool
      @native.available?(lang)
    end

    def languages : Array(String)
      @native.languages
    end

    def permission : SpeechRecognitionPermission
      @native.permission
    end

    def request_permission : SpeechRecognitionPermission
      @capabilities.try(&.require!("speech:recognize"))
      @native.request_permission
    end

    def start(lang : String = "en-US", interim : Bool = true) : Nil
      @capabilities.try(&.require!("speech:recognize"))
      @native.start(lang, interim)
    end

    def stop : Nil
      @native.stop
    end

    def abort : Nil
      @native.abort
    end

    def listening? : Bool
      @native.listening?
    end

    def on_result_event(&block : RecognitionResult -> Nil) : Nil
      @result_handlers << block
    end

    def on_result(&block : String, Bool -> Nil) : Nil
      @result_handlers << ->(result : RecognitionResult) { block.call(result.transcript, result.final?) }
    end

    def on_error(&block : String -> Nil) : Nil
      @error_handlers << block
    end

    def on_end(&block : -> Nil) : Nil
      @end_handlers << block
    end

    # :nodoc:
    def notify_result(text : String, final : Bool) : Nil
      notify_result(RecognitionResult.new(text, final))
    end

    # :nodoc:
    def notify_result(result : RecognitionResult) : Nil
      @result_handlers.each(&.call(result))
    rescue ex
      Log.warn { "Result handler error: #{ex.message}" }
    end

    # :nodoc:
    def notify_error(message : String) : Nil
      @error_handlers.each(&.call(message))
    rescue ex
      Log.warn { "Error handler error: #{ex.message}" }
    end

    # :nodoc:
    def notify_end : Nil
      @end_handlers.each(&.call)
    rescue ex
      Log.warn { "End handler error: #{ex.message}" }
    end

    def cleanup : Nil
      @native.cleanup
    end
  end
end
