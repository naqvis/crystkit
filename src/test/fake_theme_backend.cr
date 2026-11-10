require "../features/system_theme"

module CrystKit
  module Test
    # Controllable system-theme provider for specs.
    class FakeThemeProvider < Features::SystemTheme::Provider
      alias Theme = Features::SystemTheme::Theme

      property current_theme : Theme
      getter? running = false

      @changed : Proc(Theme, Nil)?

      def initialize(@current_theme : Theme = Theme::Light)
      end

      def current : Theme
        @current_theme
      end

      def start(interval : Time::Span, &changed : Theme ->) : Nil
        @running = true
        @changed = changed
      end

      def stop : Nil
        @running = false
        @changed = nil
      end

      def change(theme : Theme) : Nil
        @current_theme = theme
        @changed.try(&.call(theme))
      end
    end
  end
end
