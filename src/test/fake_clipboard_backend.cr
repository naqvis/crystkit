require "../features/clipboard"

module CrystKit
  module Test
    # In-memory clipboard provider for specs.
    #
    # Stores each clipboard flavour internally and exposes a controllable
    # `version` counter so monitoring and change-detection logic can be
    # exercised without touching the OS clipboard.
    class FakeClipboardProvider < Features::Clipboard::Provider
      getter text : String = ""
      getter image : Bytes?
      getter html : String?
      getter rtf : String?
      getter? cleared : Bool = false
      getter version : UInt64 = 1_u64

      def read_text : String
        @text
      end

      def write_text(text : String) : Nil
        @text = text
        bump
      end

      def read_image : Bytes?
        @image
      end

      def write_image(data : Bytes) : Nil
        @image = data
        bump
      end

      def read_html : String?
        @html
      end

      def write_html(html : String) : Nil
        @html = html
        bump
      end

      def read_rtf : String?
        @rtf
      end

      def write_rtf(rtf : String) : Nil
        @rtf = rtf
        bump
      end

      def clear : Nil
        @text = ""
        @image = nil
        @html = nil
        @rtf = nil
        @cleared = true
        bump
      end

      # Forces the version counter forward, simulating a clipboard change.
      def bump : Nil
        @version &+= 1
      end
    end
  end
end
