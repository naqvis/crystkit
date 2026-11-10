require "json"
require "log"
require "../core/errors"
require "../security/capability"
require "../platform/backends/printing_backend"

module CrystKit::Features
  # Print settings for a print job.
  #
  # All properties have defaults, so `PrintOptions.new` yields a sane
  # configuration. Margins are in millimeters. `scale` is a fraction of the
  # page size (`1.0` is the natural size). `output_path`, when set, writes a
  # PDF to disk instead of spooling to a physical printer.
  struct PrintOptions
    include JSON::Serializable

    # Number of copies to print. Must be positive.
    property copies : Int32

    # When `true`, orient the page in landscape; otherwise portrait.
    property? landscape : Bool

    # When `true`, request color output. Monochrome printers ignore this.
    property? color : Bool

    # Standard paper size name understood by the backend (e.g. `"A4"`, `"Letter"`).
    property paper_size : String

    # Page scale factor; `1.0` is the natural size.
    property scale : Float64

    # Top page margin in millimeters.
    property margins_top : Float64

    # Right page margin in millimeters.
    property margins_right : Float64

    # Bottom page margin in millimeters.
    property margins_bottom : Float64

    # Left page margin in millimeters.
    property margins_left : Float64

    # Optional HTML fragment rendered in the page header. `nil` omits the header.
    property header : String?

    # Optional HTML fragment rendered in the page footer. `nil` omits the footer.
    property footer : String?

    # When set, the backend writes a PDF to this filesystem path instead of
    # spooling to a printer. Used by `Printer#print_to_pdf`.
    property output_path : String?

    # Build a `PrintOptions` with CrystKit defaults applied.
    #
    # Any omitted argument falls back to its default: one copy, portrait,
    # color, A4, scale 1.0, 20mm margins on every side, and no header/footer
    # or on-disk PDF output.
    def initialize(
      @copies = 1,
      @landscape = false,
      @color = true,
      @paper_size = "A4",
      @scale = 1.0,
      @margins_top = 20.0,
      @margins_right = 20.0,
      @margins_bottom = 20.0,
      @margins_left = 20.0,
      @header = nil,
      @footer = nil,
      @output_path = nil,
    )
    end
  end

  # Platform printing facade.
  #
  # Each operation is gated by a capability check; when no capability system
  # is configured (`nil`), all operations are permitted. A `nil` webview
  # handle makes `print`, `print_to_pdf`, and `show_dialog` return `false`.
  class Printer
    Log = ::Log.for(self)

    # Create a printer facade.
    #
    # *capabilities*, when non-nil, gates each public method behind a
    # capability: `printing:print` for `print` / `show_dialog`,
    # `printing:pdf` for `print_to_pdf`, and `printing:info` for
    # `list_printers`. Operations invoked without the matching capability
    # raise `Core::SecurityError`.
    def initialize(
      @capabilities : Security::CapabilitySystem? = nil,
      @backend : Platform::PrintingBackend = Platform::CurrentPrintingBackend.new,
    )
    end

    # Print the contents of the webview *wv* using *options*.
    #
    # Requires the `printing:print` capability when a capability system is
    # configured. Returns `false` if *wv* is null, otherwise whether the
    # print job was accepted.
    #
    # ```
    # printer.print(webview, copies: 2)
    # ```
    def print(wv : Void*, options : PrintOptions = PrintOptions.new) : Bool
      @capabilities.try(&.require!("printing:print"))
      return false if wv.null?
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.print(wv, options)
      }
    end

    # Render the webview *wv* to a PDF file at *output*.
    #
    # Requires the `printing:pdf` capability when configured. *output* is a
    # filesystem path. Returns `false` if *wv* is null, otherwise whether the
    # PDF was written.
    def print_to_pdf(wv : Void*, output : String, options : PrintOptions = PrintOptions.new) : Bool
      @capabilities.try(&.require!("printing:pdf"))
      return false if wv.null?
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.print_to_pdf(wv, output, options)
      }
    end

    # Enumerate the names of printers known to the platform.
    #
    # Requires the `printing:info` capability when configured. The returned
    # array may be empty when no printers are installed but is never `nil`.
    def list_printers : Array(String)
      @capabilities.try(&.require!("printing:info"))
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.list_printers
      }
    end

    # Display the native print dialog for the webview *wv*.
    #
    # Requires the `printing:print` capability when configured (shares the
    # print capability with `#print`). Returns `false` if *wv* is null,
    # otherwise whether the user confirmed the dialog.
    def show_dialog(wv : Void*, options : PrintOptions = PrintOptions.new) : Bool
      @capabilities.try(&.require!("printing:print"))
      return false if wv.null?
      ::CrystKit::Core::MainThread.dispatch_sync {
        @backend.show_dialog(wv, options)
      }
    end
  end
end
