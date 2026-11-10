require "../interface"

{% if flag?(:darwin) %}
  require "../macos/printing"
{% elsif flag?(:linux) %}
  require "../linux/printing"
{% elsif flag?(:windows) %}
  require "../windows/printing"
{% end %}

module CrystKit
  module Platform
    # Abstract interface for native printing and PDF export.
    abstract class PrintingBackend
      # Prints the contents of the window identified by *window_ptr* using
      # *options*, returning `true` on success.
      abstract def print(window : Void*, options) : Bool

      # Renders the window contents to a PDF file at *output* using *options*,
      # returning `true` on success.
      abstract def print_to_pdf(window : Void*, output : String, options) : Bool

      # Returns the names of printers available to the system.
      abstract def list_printers : Array(String)

      # Presents the native print dialog for *window_ptr* with *options*,
      # returning `true` when the user confirms the print.
      abstract def show_dialog(window : Void*, options) : Bool
    end

    # :nodoc:
    class CurrentPrintingBackend < PrintingBackend
      # :nodoc:
      def print(window : Void*, options) : Bool
        Current::Printing.print(window, options)
      end

      # :nodoc:
      def print_to_pdf(window : Void*, output : String, options) : Bool
        Current::Printing.print_to_pdf(window, output, options)
      end

      # :nodoc:
      def list_printers : Array(String)
        Current::Printing.list_printers
      end

      # :nodoc:
      def show_dialog(window : Void*, options) : Bool
        Current::Printing.show_dialog(window, options)
      end
    end
  end
end
