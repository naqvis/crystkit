require "log"
require "uri"
require "native_desktop"
require "../core/errors"
require "../security/capability"

module CrystKit::Features
  # :nodoc:
  abstract class ExternalProvider
    abstract def open(target : String, application : String?) : Nil
  end

  # :nodoc:
  class NativeExternalProvider < ExternalProvider
    def open(target : String, application : String?) : Nil
      ::NativeDesktop.applications.open(target, application)
    rescue ex : ::NativeDesktop::Error
      raise Core::Error.new(ex.message || "Failed to open target", code: "OPEN_FAILED")
    end
  end

  # Options for opening a resource with an external application.
  #
  # Passed to the `ExternalOpener` open methods to override the default
  # system handler.
  struct OpenOptions
    # Optional specific application to use for opening.
    # When nil the default system application is used.
    property application : String?

    # Creates a set of open options with *application* left as the default
    # system handler when omitted.
    def initialize(@application = nil)
    end
  end

  # Opens URLs and files using the default or a specified external application.
  #
  # Hands a URL, file, or directory path to the OS's "open" command so it is
  # rendered by the user's preferred handler. Every entry point enforces the
  # `"external:open"` capability, validates its input, and rejects dangerous
  # file types to prevent accidental execution of scripts or executables.
  #
  # All open operations require the "external:open" capability.
  class ExternalOpener
    # Dangerous file extensions that must not be opened directly.
    #
    # `#open_file` rejects these with a `Core::ValidationError`.
    DANGEROUS_EXTENSIONS = {
      ".exe", ".bat", ".cmd", ".com", ".msi", ".ps1", ".vbs", ".js",
      ".jar", ".sh", ".bash", ".zsh", ".fish", ".csh", ".ksh",
      ".scr", ".pif", ".reg", ".inf", ".dll", ".so", ".dylib",
    }

    @capabilities : Security::CapabilitySystem

    # Creates an opener bound to *capabilities*.
    #
    # *capabilities* is required because every open call enforces the
    # `"external:open"` capability.
    def initialize(
      @capabilities : Security::CapabilitySystem,
      @provider : ExternalProvider = NativeExternalProvider.new,
    )
    end

    # Open a URL in the default system browser.
    #
    # The URL is validated before opening. Supported schemes include
    # http, https, ftp, ftps, and platform-specific schemes (27.7).
    #
    # Raises `Core::SecurityError`   if the "external:open" capability is missing.
    # Raises `Core::ValidationError` if the URL is invalid.
    # Raises `Core::Error`    if the OS fails to open the URL.
    def open_url(url : String, options : OpenOptions = OpenOptions.new) : Nil
      @capabilities.require!("external:open", url)

      validate_url!(url)

      Log.debug { "ExternalOpener: opening URL #{url.inspect}" }
      run_opener(url, options)
    end

    # Open a file with the default system application.
    #
    # The path must be an existing file. Dangerous file types (executables,
    # scripts, etc.) are rejected to prevent accidental execution.
    #
    # Raises `Core::SecurityError`   if the "external:open" capability is missing.
    # Raises `Core::ValidationError` if the path is invalid or the file type is dangerous.
    # Raises `Core::FileSystemError` if the file does not exist.
    # Raises `Core::Error`    if the OS fails to open the file.
    def open_file(path : String, options : OpenOptions = OpenOptions.new) : Nil
      @capabilities.require!("external:open", path)

      validate_file_path!(path)

      Log.debug { "ExternalOpener: opening file #{path.inspect}" }
      run_opener(path, options)
    end

    # Open the file explorer at the specified directory path.
    #
    # Raises `Core::SecurityError`   if the "external:open" capability is missing.
    # Raises `Core::ValidationError` if the path is invalid.
    # Raises `Core::Error`    if the OS fails to open the path.
    def open_path(path : String, options : OpenOptions = OpenOptions.new) : Nil
      @capabilities.require!("external:open", path)

      validate_path!(path)

      Log.debug { "ExternalOpener: opening path #{path.inspect}" }
      run_opener(path, options)
    end

    # Private helpers

    # :nodoc:
    # Validate that *url* has an acceptable scheme.
    private def validate_url!(url : String) : Nil
      uri = URI.parse(url)
      scheme = uri.scheme.try(&.downcase)

      if !scheme || scheme.empty?
        raise Core::ValidationError.new(
          "Invalid URL: missing scheme in #{url.inspect}",
          field: "url"
        )
      end

      # Allow common internet schemes and platform-specific custom schemes.
      # Reject obviously dangerous ones like javascript: or data:.
      if {"javascript", "data", "vbscript"}.includes?(scheme)
        raise Core::ValidationError.new(
          "Dangerous URL scheme #{scheme.inspect} is not allowed",
          field: "url"
        )
      end
    rescue URI::Error
      raise Core::ValidationError.new(
        "Invalid URL: #{url.inspect}",
        field: "url"
      )
    end

    # :nodoc:
    # Validate that *path* points to an existing file and is not dangerous.
    private def validate_file_path!(path : String) : Nil
      validate_path!(path)

      ext = File.extname(path).downcase
      if DANGEROUS_EXTENSIONS.includes?(ext)
        raise Core::ValidationError.new(
          "Opening files with extension #{ext.inspect} is not allowed for security reasons",
          field: "path"
        )
      end

      unless File.file?(path)
        raise Core::FileSystemError.new(
          "File not found: #{path.inspect}",
          code: "FILE_NOT_FOUND"
        )
      end
    end

    # :nodoc:
    # Validate that *path* is non-empty.
    private def validate_path!(path : String) : Nil
      if path.strip.empty?
        raise Core::ValidationError.new(
          "Path must not be empty",
          field: "path"
        )
      end
    end

    # :nodoc:
    # Dispatch to the native desktop opener.
    # When *options.application* is set, that application is used directly.
    private def run_opener(target : String, options : OpenOptions) : Nil
      @provider.open(target, options.application)
    end
  end
end
