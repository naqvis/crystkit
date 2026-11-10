require "json"
require "log"
require "native_desktop"
require "../core/errors"

module CrystKit
  module Features
    # Modifier keys for keyboard shortcuts.
    #
    # `Meta` is Command on macOS and the Windows key on Windows.
    enum Modifier
      Ctrl
      Alt
      Shift
      Meta # Cmd on macOS, Win on Windows
    end

    # Keys supported in global shortcuts: the printable US-ASCII keyboard,
    # function keys F1–F12, navigation/editing keys, and common punctuation.
    enum Key
      # Alphanumeric
      A; B; C; D; E; F; G; H; I; J; K; L; M
      N; O; P; Q; R; S; T; U; V; W; X; Y; Z
      Num0; Num1; Num2; Num3; Num4; Num5; Num6; Num7; Num8; Num9

      # Function keys
      F1; F2; F3; F4; F5; F6; F7; F8; F9; F10; F11; F12

      # Special keys
      Space; Enter; Tab; Escape; Backspace; Delete
      Left; Right; Up; Down
      Home; End; PageUp; PageDown
      Comma; Period; Semicolon; Quote; BracketLeft; BracketRight
      Backslash; Slash; Minus; Equal
    end

    # A parsed keyboard shortcut, the structured form of an accelerator string
    # such as `"Ctrl+Shift+S"`. `accelerator` preserves the original spelling.
    struct Shortcut
      # Modifiers that must be held, in the order specified by the user.
      getter modifiers : Array(Modifier)

      # Non-modifier key that triggers the shortcut.
      getter key : Key

      # Original accelerator string passed by the caller, e.g. `"Ctrl+Shift+S"`.
      getter accelerator : String

      # Build a `Shortcut` from its constituent parts.
      def initialize(@modifiers : Array(Modifier), @key : Key, @accelerator : String)
      end
    end

    # Global keyboard shortcut manager.
    #
    # Shortcuts are system-wide and fire even when the app is not focused.
    # Registration only updates in-memory state; the OS event tap is created
    # when `start_listening` is called.
    #
    # Usage:
    #
    # ```
    # shortcuts = GlobalShortcuts.new
    # shortcuts.register("Ctrl+Shift+S") { puts "Screenshot!" }
    # shortcuts.register("Ctrl+Q") { exit }
    # shortcuts.start_listening # opens the OS event tap and begins receiving keys
    # # ... later ...
    # shortcuts.stop_listening # tears down the OS event tap
    # ```
    class GlobalShortcuts
      # Native integration seam used by CrystKit and by feature tests.
      abstract class Provider
        abstract def register(shortcut : Shortcut, handler : Proc(Nil)) : Nil
        abstract def unregister(shortcut : Shortcut) : Nil
        abstract def start : Nil
        abstract def stop : Nil
      end

      # :nodoc:
      class NativeProvider < Provider
        def initialize(@native = ::NativeDesktop::GlobalShortcuts.new)
        end

        def register(shortcut : Shortcut, handler : Proc(Nil)) : Nil
          @native.register(native_shortcut(shortcut), &handler)
        end

        def unregister(shortcut : Shortcut) : Nil
          @native.unregister(native_shortcut(shortcut))
        end

        def start : Nil
          @native.start
        end

        def stop : Nil
          @native.stop
        end

        private def native_shortcut(shortcut : Shortcut) : ::NativeDesktop::Shortcut
          modifiers = shortcut.modifiers.map { |modifier| ::NativeDesktop::ShortcutModifier.from_value(modifier.value) }
          ::NativeDesktop::Shortcut.new(modifiers, ::NativeDesktop::ShortcutKey.from_value(shortcut.key.value))
        end
      end

      # :nodoc:
      @shortcuts : Hash(String, ShortcutEntry)
      # :nodoc:
      @listening : Bool

      # Build a `GlobalShortcuts` instance with the native provider.
      #
      # The instance begins not-listening; call `start_listening` after
      # registering shortcuts.
      def initialize(@provider : Provider = NativeProvider.new)
        @shortcuts = Hash(String, ShortcutEntry).new
        @listening = false
      end

      # Register a global shortcut. Raises if the accelerator is invalid or
      # conflicts with an already-registered shortcut. If `start_listening`
      # has been called, the shortcut is also registered with the OS.
      def register(accelerator : String, &handler : ->) : Nil
        shortcut = parse_accelerator(accelerator)
        normalized = normalize_accelerator(shortcut)

        if @shortcuts.has_key?(normalized)
          raise Core::Error.new(
            "Shortcut '#{accelerator}' is already registered",
            code: "SHORTCUT_CONFLICT"
          )
        end

        entry = ShortcutEntry.new(shortcut, handler)
        begin
          @provider.register(shortcut, handler)
          @shortcuts[normalized] = entry
        rescue ex
          raise Core::Error.new(
            "Failed to register shortcut '#{accelerator}': #{ex.message}",
            code: "SHORTCUT_REGISTER_FAILED"
          )
        end
      end

      # Unregister a global shortcut. If currently listening, also unregisters
      # it with the OS.
      def unregister(accelerator : String) : Nil
        shortcut = parse_accelerator(accelerator)
        normalized = normalize_accelerator(shortcut)

        return unless @shortcuts.has_key?(normalized)

        @provider.unregister(shortcut)
        @shortcuts.delete(normalized)
      end

      # Unregister all registered shortcuts.
      def unregister_all : Nil
        @shortcuts.each_value do |entry|
          begin
            @provider.unregister(entry.shortcut)
          rescue ex
            Log.warn { "GlobalShortcuts: failed to unregister #{entry.shortcut.accelerator}: #{ex.message}" }
          end
        end
        @shortcuts.clear
      end

      # Begin listening for global key events. Registers every currently-known
      # shortcut. Must be called before any registered handler can fire.
      # Idempotent.
      def start_listening : Nil
        return if @listening

        @provider.start
        @listening = true
      end

      # Stop listening for global key events. Registered shortcuts remain and
      # will be re-registered if `start_listening` is called again. Idempotent.
      def stop_listening : Nil
        return unless @listening
        @provider.stop
        @listening = false
      end

      # Returns whether listening is currently active.
      def listening? : Bool
        @listening
      end

      # Returns all registered accelerator strings.
      def registered : Array(String)
        @shortcuts.keys
      end

      # Called internally when a shortcut is triggered by the OS.
      #
      # Re-parses *accelerator*, normalizes it, and invokes the registered
      # handler if one matches. Unknown accelerators are silently ignored so
      # a stray platform event does not crash the app. Intended to be called
      # by the platform backend, not by application code.
      # :nodoc:
      def trigger(accelerator : String)
        shortcut = parse_accelerator(accelerator)
        normalized = normalize_accelerator(shortcut)
        @shortcuts[normalized]?.try(&.handler.call)
      end

      # Parse an accelerator string like "Ctrl+Shift+A" into a Shortcut.
      def parse_accelerator(accelerator : String) : Shortcut
        parts = accelerator.split("+").map(&.strip)
        raise Core::Error.new("Empty accelerator", code: "INVALID_ACCELERATOR") if parts.empty?

        modifiers = [] of Modifier
        key_str = parts.last
        modifier_strs = parts[0..-2]

        modifier_strs.each do |mod|
          case mod.downcase
          when "ctrl", "control"    then modifiers << Modifier::Ctrl
          when "alt"                then modifiers << Modifier::Alt
          when "shift"              then modifiers << Modifier::Shift
          when "meta", "cmd", "win" then modifiers << Modifier::Meta
          when "cmdorctrl"
            {% if flag?(:darwin) %}
              modifiers << Modifier::Meta
            {% else %}
              modifiers << Modifier::Ctrl
            {% end %}
          else
            raise Core::Error.new(
              "Unknown modifier: '#{mod}' in accelerator '#{accelerator}'",
              code: "INVALID_ACCELERATOR"
            )
          end
        end

        key = parse_key(key_str, accelerator)
        Shortcut.new(modifiers, key, accelerator)
      end

      # Lookup table mapping upper-cased accelerator key tokens (as they appear
      # in an accelerator string such as `"Ctrl+S"`) to the corresponding
      # `Key` enum value. Exposed as a constant so platform backends can reuse
      # the same spelling list when validating user input.
      # :nodoc:
      KEY_MAP = {
        "A" => Key::A, "B" => Key::B, "C" => Key::C, "D" => Key::D,
        "E" => Key::E, "F" => Key::F, "G" => Key::G, "H" => Key::H,
        "I" => Key::I, "J" => Key::J, "K" => Key::K, "L" => Key::L,
        "M" => Key::M, "N" => Key::N, "O" => Key::O, "P" => Key::P,
        "Q" => Key::Q, "R" => Key::R, "S" => Key::S, "T" => Key::T,
        "U" => Key::U, "V" => Key::V, "W" => Key::W, "X" => Key::X,
        "Y" => Key::Y, "Z" => Key::Z,
        "0" => Key::Num0, "1" => Key::Num1, "2" => Key::Num2, "3" => Key::Num3,
        "4" => Key::Num4, "5" => Key::Num5, "6" => Key::Num6, "7" => Key::Num7,
        "8" => Key::Num8, "9" => Key::Num9,
        "F1" => Key::F1, "F2" => Key::F2, "F3" => Key::F3, "F4" => Key::F4,
        "F5" => Key::F5, "F6" => Key::F6, "F7" => Key::F7, "F8" => Key::F8,
        "F9" => Key::F9, "F10" => Key::F10, "F11" => Key::F11, "F12" => Key::F12,
        "SPACE" => Key::Space, "ENTER" => Key::Enter, "TAB" => Key::Tab,
        "ESCAPE" => Key::Escape, "ESC" => Key::Escape,
        "BACKSPACE" => Key::Backspace, "DELETE" => Key::Delete,
        "LEFT" => Key::Left, "RIGHT" => Key::Right, "UP" => Key::Up, "DOWN" => Key::Down,
        "HOME" => Key::Home, "END" => Key::End, "PAGEUP" => Key::PageUp, "PAGEDOWN" => Key::PageDown,
        "," => Key::Comma, "." => Key::Period, ";" => Key::Semicolon, "'" => Key::Quote,
        "[" => Key::BracketLeft, "]" => Key::BracketRight, "\\" => Key::Backslash,
        "/" => Key::Slash, "-" => Key::Minus, "=" => Key::Equal,
        "COMMA" => Key::Comma, "PERIOD" => Key::Period, "SEMICOLON" => Key::Semicolon,
        "QUOTE" => Key::Quote, "BRACKETLEFT" => Key::BracketLeft, "BRACKETRIGHT" => Key::BracketRight,
        "BACKSLASH" => Key::Backslash, "SLASH" => Key::Slash, "MINUS" => Key::Minus, "EQUAL" => Key::Equal,
      }

      # :nodoc:
      private def parse_key(key_str : String, accelerator : String) : Key
        KEY_MAP[key_str.upcase]? || raise Core::Error.new(
          "Unknown key: '#{key_str}' in accelerator '#{accelerator}'",
          code: "INVALID_ACCELERATOR"
        )
      end

      # :nodoc:
      private def normalize_accelerator(shortcut : Shortcut) : String
        mods = shortcut.modifiers.map(&.to_s).sort!.join("+")
        key = shortcut.key.to_s
        mods.empty? ? key : "#{mods}+#{key}"
      end

      # :nodoc:
      private struct ShortcutEntry
        getter shortcut : Shortcut
        getter handler : Proc(Nil)

        def initialize(@shortcut : Shortcut, @handler : Proc(Nil))
        end
      end
    end
  end
end
