require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../security/capability"

module CrystKit
  module Features
    # Image formats supported by the clipboard for image read/write operations.
    #
    # The native implementation may support only a subset of these formats depending
    # on the platform. `PNG` is the interchange format used by the current
    # native implementations
    # for both reading and writing; `JPEG` and `BMP` are reported by Windows
    # when reading DIB data converted from those sources. Callers should
    # prefer `PNG` for cross-platform image clipboard transfers.
    enum ImageFormat
      # Portable Network Graphics — the canonical interchange format on macOS and Linux.
      PNG
      # JPEG bitmap — primarily observed on Windows clipboard conversions.
      JPEG
      # Windows bitmap format — emitted by the Windows DIB clipboard path.
      BMP
    end

    # An image payload read from or written to the system clipboard.
    #
    # `ClipboardImage` is the value type returned by `Clipboard#read_image`
    # and accepted by `Clipboard#write_image`. It bundles the raw encoded
    # image bytes with the pixel dimensions and the `ImageFormat` the bytes
    # are encoded in. The current native implementations return `ImageFormat::PNG`
    # with zeroed dimensions on read; the *width* and *height* fields are
    # reserved for implementations that can extract them without re-decoding
    # the buffer.
    struct ClipboardImage
      # Raw encoded image bytes (PNG on macOS/Linux, DIB on Windows).
      getter data : Bytes
      # Image width in pixels; `0` when it cannot be determined cheaply.
      getter width : Int32
      # Image height in pixels; `0` when it cannot be determined cheaply.
      getter height : Int32
      # Format of the bytes in `#data`.
      getter format : ImageFormat

      # Creates a clipboard image value from pre-encoded *data*.
      #
      # The bytes are stored by reference; callers must not mutate the
      # buffer after handing it to this constructor.
      def initialize(@data : Bytes, @width : Int32, @height : Int32, @format : ImageFormat)
      end
    end

    # Cross-platform clipboard access with capability-based security.
    #
    # The clipboard class provides a unified API for reading and writing various
    # data formats to the system clipboard. All operations require appropriate
    # capabilities (clipboard:read or clipboard:write).
    #
    # ## Supported Formats
    #
    # - **Text**: Plain UTF-8 text (universal support)
    # - **HTML**: Rich HTML content (macOS, Windows, partial Linux support)
    # - **RTF**: Rich Text Format (macOS, Windows only)
    # - **Image**: PNG image data (all platforms with varying support)
    #
    # ## Usage
    #
    # ```
    # caps = Security::CapabilitySystem.new
    # caps.grant("clipboard:read")
    # caps.grant("clipboard:write")
    # clipboard = Clipboard.new(caps)
    #
    # # Read/write text
    # clipboard.write_text("Hello, World!")
    # text = clipboard.read_text
    #
    # # Monitor clipboard changes
    # clipboard.on_change { puts "Clipboard changed!" }
    # clipboard.start_monitoring
    # ```
    class Clipboard
      # :nodoc:
      Log = ::Log.for(self)

      # Internal boundary between CrystKit's capability checks and the native
      # desktop implementation. Application code does not provide this.
      # :nodoc:
      abstract class Provider
        abstract def read_text : String
        abstract def write_text(text : String) : Nil
        abstract def read_image : Bytes?
        abstract def write_image(data : Bytes) : Nil
        abstract def read_html : String?
        abstract def write_html(html : String) : Nil
        abstract def read_rtf : String?
        abstract def write_rtf(rtf : String) : Nil
        abstract def clear : Nil
        abstract def version : UInt64
      end

      # :nodoc:
      class NativeProvider < Provider
        def read_text : String
          ::NativeDesktop.clipboard.read_text
        end

        def write_text(text : String) : Nil
          ::NativeDesktop.clipboard.write_text(text)
        end

        def read_image : Bytes?
          ::NativeDesktop.clipboard.read_image
        end

        def write_image(data : Bytes) : Nil
          ::NativeDesktop.clipboard.write_image(data)
        end

        def read_html : String?
          ::NativeDesktop.clipboard.read_html
        end

        def write_html(html : String) : Nil
          ::NativeDesktop.clipboard.write_html(html)
        end

        def read_rtf : String?
          ::NativeDesktop.clipboard.read_rtf
        end

        def write_rtf(rtf : String) : Nil
          ::NativeDesktop.clipboard.write_rtf(rtf)
        end

        def clear : Nil
          ::NativeDesktop.clipboard.clear
        end

        def version : UInt64
          ::NativeDesktop.clipboard.version
        end
      end

      # Maximum number of bytes accepted by `write_text`, `write_html`,
      # `write_rtf`, and `write_image` before the operation is rejected.
      #
      # The limit protects the platform clipboard IPC from pathological
      # inputs. Set to 10 MB to accommodate large legitimate payloads (e.g.
      # pasting a high-resolution screenshot) while still bounding memory.
      MAX_TEXT_SIZE = 10_000_000

      # :nodoc:
      @capabilities : Security::CapabilitySystem
      # :nodoc:
      @change_handler : Proc(Nil)?
      # :nodoc:
      @monitoring : Bool = false

      # Creates a clipboard client gated by *capabilities*.
      #
      # Every read/write method on the resulting instance calls
      # `Security::CapabilitySystem#require!` with `clipboard:read` or
      # `clipboard:write` before touching the native clipboard, so the
      # capability system must have those capabilities granted (or a
      # manifest loaded) before the calls will succeed.
      #
      # Platform selection and GUI-thread dispatch are handled internally.
      def initialize(@capabilities : Security::CapabilitySystem,
                     @provider : Provider = NativeProvider.new)
      end

      # Wraps a clipboard operation: re-raises CrystKitError, wraps others.
      # :nodoc:
      private def wrap_clipboard_op(operation : String, error_code : String, &)
        yield
      rescue ex
        Log.error { "Clipboard: #{operation} failed: #{ex.message}" }
        raise Core::Error.new(
          "Failed to #{operation} clipboard: #{ex.message}",
          code: error_code
        )
      end

      # Wraps a clipboard read that can gracefully degrade to nil.
      # :nodoc:
      private def wrap_clipboard_read(operation : String, &)
        yield
      rescue ex
        Log.warn { "Clipboard: #{operation} failed: #{ex.message}" }
        nil
      end

      # Read text from the system clipboard.
      #
      # Requires: clipboard:read capability
      #
      # Returns an empty string if the clipboard is empty or contains no
      # text. The returned string is UTF-8 decoded by the native implementation.
      #
      # Raises `Core::SecurityError` if `clipboard:read` is not granted,
      # and `Core::Error` (code `CLIPBOARD_READ_ERROR`) if the
      # native clipboard operation fails.
      #
      # ```
      # clipboard.write_text("Hello, World!")
      # clipboard.read_text # => "Hello, World!"
      # ```
      def read_text : String
        @capabilities.require!("clipboard:read")
        wrap_clipboard_op("read_text", "CLIPBOARD_READ_ERROR") do
          @provider.read_text
        end
      end

      # Write text to the system clipboard.
      #
      # Requires: clipboard:write capability
      #
      # Raises `Core::Error` (code `CLIPBOARD_TEXT_TOO_LARGE`) if
      # the text exceeds `MAX_TEXT_SIZE`, `Core::SecurityError` if
      # `clipboard:write` is not granted, and `Core::Error` (code
      # `CLIPBOARD_WRITE_ERROR`) if the native operation fails.
      #
      # ```
      # clipboard.write_text("Hello, World!")
      # ```
      def write_text(text : String) : Nil
        @capabilities.require!("clipboard:write")

        if text.bytesize > MAX_TEXT_SIZE
          raise Core::Error.new(
            "Text size (#{text.bytesize} bytes) exceeds maximum (#{MAX_TEXT_SIZE} bytes)",
            code: "CLIPBOARD_TEXT_TOO_LARGE"
          )
        end

        wrap_clipboard_op("write_text", "CLIPBOARD_WRITE_ERROR") do
          @provider.write_text(text)
        end
      end

      # Read an image from the system clipboard.
      #
      # Requires: clipboard:read capability
      #
      # Returns `nil` if the clipboard contains no image data or the
      # native clipboard cannot decode it. Failures are logged at warn
      # level and degrade to `nil` rather than raising, so callers can use
      # this in paste handlers without rescuing.
      #
      # **Platform notes:**
      # - macOS: Returns PNG data from NSPasteboard
      # - Linux: Returns PNG data via xclip/wl-clipboard
      # - Windows: Returns DIB (Device Independent Bitmap) data
      def read_image : ClipboardImage?
        @capabilities.require!("clipboard:read")

        wrap_clipboard_read("read_image") do
          if data = @provider.read_image
            ClipboardImage.new(data, 0, 0, ImageFormat::PNG)
          end
        end
      end

      # Write an image to the system clipboard.
      #
      # Requires: clipboard:write capability
      #
      # Expects PNG-formatted image data on macOS and Linux. On Windows,
      # expects DIB (Device Independent Bitmap) format.
      #
      # Raises `Core::Error` (code `CLIPBOARD_IMAGE_TOO_LARGE`)
      # if the image exceeds `MAX_TEXT_SIZE`, `CLIPBOARD_INVALID_IMAGE`
      # if `image.data` is empty, `Core::SecurityError` if
      # `clipboard:write` is not granted, and `CLIPBOARD_WRITE_ERROR` on
      # native operation failure.
      def write_image(image : ClipboardImage) : Nil
        @capabilities.require!("clipboard:write")

        if image.data.size > MAX_TEXT_SIZE
          raise Core::Error.new(
            "Image size (#{image.data.size} bytes) exceeds maximum (#{MAX_TEXT_SIZE} bytes)",
            code: "CLIPBOARD_IMAGE_TOO_LARGE"
          )
        end

        if image.data.empty?
          raise Core::Error.new(
            "Image data is empty",
            code: "CLIPBOARD_INVALID_IMAGE"
          )
        end

        wrap_clipboard_op("write_image", "CLIPBOARD_WRITE_ERROR") do
          @provider.write_image(image.data)
        end
      end

      # Read HTML content from the clipboard.
      #
      # Requires: clipboard:read capability
      #
      # Returns `nil` if the clipboard contains no HTML data or if HTML is
      # not supported on the current platform. As with `#read_image`,
      # decode failures degrade to `nil` instead of raising.
      def read_html : String?
        @capabilities.require!("clipboard:read")
        wrap_clipboard_read("read_html") { @provider.read_html }
      end

      # Write HTML content to the clipboard.
      #
      # Requires: clipboard:write capability
      #
      # On platforms that support HTML clipboard data, this writes both the
      # HTML and a plain-text fallback. On platforms without HTML support,
      # only the plain-text fallback is written.
      #
      # Raises `Core::Error` (code `CLIPBOARD_HTML_TOO_LARGE`)
      # if *html* exceeds `MAX_TEXT_SIZE`.
      def write_html(html : String) : Nil
        @capabilities.require!("clipboard:write")

        if html.bytesize > MAX_TEXT_SIZE
          raise Core::Error.new(
            "HTML size (#{html.bytesize} bytes) exceeds maximum (#{MAX_TEXT_SIZE} bytes)",
            code: "CLIPBOARD_HTML_TOO_LARGE"
          )
        end

        wrap_clipboard_op("write_html", "CLIPBOARD_WRITE_ERROR") do
          @provider.write_html(html)
        end
      end

      # Read RTF (Rich Text Format) content from the clipboard.
      #
      # Requires: clipboard:read capability
      #
      # Returns `nil` if the clipboard contains no RTF data or if RTF is
      # not supported on the current platform (Linux).
      def read_rtf : String?
        @capabilities.require!("clipboard:read")
        wrap_clipboard_read("read_rtf") { @provider.read_rtf }
      end

      # Write RTF (Rich Text Format) content to the clipboard.
      #
      # Requires: clipboard:write capability
      #
      # On Linux, this falls back to writing plain text since RTF is not
      # widely supported by clipboard tools.
      #
      # Raises `Core::Error` (code `CLIPBOARD_RTF_TOO_LARGE`) if
      # *rtf* exceeds `MAX_TEXT_SIZE`.
      def write_rtf(rtf : String) : Nil
        @capabilities.require!("clipboard:write")

        if rtf.bytesize > MAX_TEXT_SIZE
          raise Core::Error.new(
            "RTF size (#{rtf.bytesize} bytes) exceeds maximum (#{MAX_TEXT_SIZE} bytes)",
            code: "CLIPBOARD_RTF_TOO_LARGE"
          )
        end

        wrap_clipboard_op("write_rtf", "CLIPBOARD_WRITE_ERROR") do
          @provider.write_rtf(rtf)
        end
      end

      # Clear the clipboard, removing all content.
      #
      # Requires: clipboard:write capability
      #
      # Raises `Core::SecurityError` if `clipboard:write` is not granted,
      # and `Core::Error` (code `CLIPBOARD_CLEAR_ERROR`) on
      # native operation failure.
      def clear : Nil
        @capabilities.require!("clipboard:write")
        wrap_clipboard_op("clear", "CLIPBOARD_CLEAR_ERROR") do
          @provider.clear
        end
      end

      # Register a handler called when clipboard content changes.
      #
      # Note: registration alone does not start polling. Call
      # `start_monitoring` to begin watching for changes. Only one handler
      # is supported at a time; registering again replaces the previous
      # handler.
      #
      # ```
      # clipboard.on_change { puts "Clipboard changed!" }
      # clipboard.start_monitoring
      # ```
      def on_change(&block : ->)
        @change_handler = block
      end

      # Start polling the clipboard for changes.
      #
      # Calls registered `on_change` handlers when the clipboard version changes.
      # Polling runs in a background fiber until `stop_monitoring` is called.
      #
      # The version is checked every 500ms using platform-specific mechanisms:
      # - macOS: NSPasteboard changeCount (efficient, no data transfer)
      # - Windows: GetClipboardSequenceNumber (efficient, no data transfer)
      # - Linux: Hash of clipboard text (expensive, reads content)
      def start_monitoring : Nil
        return if @monitoring
        @monitoring = true

        Core::Fibers.spawn do
          last_version = clipboard_version
          while @monitoring
            sleep 500.milliseconds
            break unless @monitoring

            begin
              current = clipboard_version
              if current != last_version
                last_version = current
                handle_change
              end
            rescue ex
              Log.warn { "Clipboard: monitoring error: #{ex.message}" }
            end
          end
        end
      end

      # Stop the background polling fiber.
      #
      # The fiber exits on its next iteration; there is no immediate
      # cancellation. Safe to call when monitoring was never started.
      def stop_monitoring : Nil
        @monitoring = false
      end

      # Get a version number that changes whenever the clipboard content changes.
      #
      # This is useful for monitoring clipboard changes without reading the actual
      # content. The version number is platform-specific:
      #
      # - **macOS**: NSPasteboard changeCount (monotonic counter)
      # - **Windows**: GetClipboardSequenceNumber (monotonic counter)
      # - **Linux**: Hash of clipboard text (expensive, reads content)
      def clipboard_version : UInt64
        @provider.version
      rescue ex
        Log.warn { "Clipboard: version failed: #{ex.message}" }
        Time.utc.to_unix_ms.to_u64
      end

      # Called internally when clipboard content changes.
      # :nodoc:
      def handle_change
        @change_handler.try(&.call)
      end
    end
  end
end
