require "log"
require "native_desktop"
require "../core/errors"

module CrystKit::Features
  # Options for `Autostart#enable`.
  #
  # Options are forwarded to the operating-system service. Applications should
  # treat them as hints because login mechanisms do not expose identical
  # behavior on every platform.
  struct AutostartOptions
    # Additional command-line arguments appended to the executable path
    # when the OS launches the application at login.
    #
    # Defaults to an empty array. The arguments are passed verbatim to the
    # platform's launch entry and are not shell-expanded.
    property args : Array(String) = [] of String

    # When `true`, `--minimized` is appended to the launch arguments.
    #
    # The application is responsible for interpreting that argument and
    # choosing its initial window state.
    property? minimized : Bool = false

    # Delay before the application starts after login.
    #
    # A value of `0.seconds` means "start immediately". Linux represents a
    # positive value with `X-GNOME-Autostart-Delay`. The macOS LaunchAgent and
    # Windows login-registry implementations ignore it because neither
    # mechanism provides an equivalent one-shot login delay.
    property delay : Time::Span = 0.seconds

    # Builds an options bundle with the given *args*, *minimized* flag, and
    # *delay* span, defaulting to no args, visible launch, and no delay.
    def initialize(@args = [] of String, @minimized = false, @delay = 0.seconds)
    end
  end

  # Manages application autostart registration with the operating system.
  #
  # Allows an application to register itself to launch automatically when the
  # user logs in, using platform-specific mechanisms:
  #   - Linux:   XDG autostart `.desktop` file in `~/.config/autostart/`
  #   - Windows: Registry key `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  #   - macOS:   Launch agent plist in `~/Library/LaunchAgents/`
  #
  # The class owns no platform state itself, only the application identity
  # (`app_name` and `app_path`) forwarded to the native desktop service. Operations
  # are not transactional — a failed `#enable` may leave a partial OS entry
  # behind, in which case a subsequent `#disable` is the recommended
  # recovery path.
  #
  # All methods re-raise backend failures as `Core::Error` with
  # stable error codes (`AUTOSTART_REGISTER_FAILED`,
  # `AUTOSTART_UNREGISTER_FAILED`) so callers can match on `#code` for
  # targeted recovery. `#enabled?` is the exception: it logs and returns
  # `false` on backend errors to keep UI status checks non-throwing.
  #
  # ```
  # autostart = CrystKit::Features::Autostart.new("My App", Path.new("/usr/bin/myapp"))
  # autostart.enable
  # puts autostart.enabled? # => true
  # autostart.disable
  # puts autostart.enabled? # => false
  # ```
  class Autostart
    # :nodoc:
    abstract class Provider
      abstract def enable(entry : ::NativeDesktop::AutostartEntry) : Nil
      abstract def disable(name : String) : Nil
      abstract def enabled?(name : String) : Bool
    end

    # :nodoc:
    class NativeProvider < Provider
      def enable(entry : ::NativeDesktop::AutostartEntry) : Nil
        ::NativeDesktop.autostart.enable(entry)
      end

      def disable(name : String) : Nil
        ::NativeDesktop.autostart.disable(name)
      end

      def enabled?(name : String) : Bool
        ::NativeDesktop.autostart.enabled?(name)
      end
    end

    # Human-readable application name used in autostart entries.
    getter app_name : String

    # Absolute path to the application executable.
    getter app_path : Path

    # Create a new Autostart manager.
    #
    # - *app_name*: Human-readable name for the application (used in OS entries).
    # - *app_path*: Absolute path to the application executable.
    def initialize(@app_name : String, @app_path : Path, @provider : Provider = NativeProvider.new)
    end

    # Register the application for autostart with the operating system.
    #
    # Uses platform-specific mechanisms to ensure the application launches
    # automatically when the user logs in.
    #
    # - *options*: Optional `AutostartOptions` to configure args, minimized mode,
    #   and startup delay.
    #
    # Raises `Core::Error` if registration fails.
    def enable(options : AutostartOptions = AutostartOptions.new) : Nil
      platform_enable(options)
      Log.debug { "Autostart: registered '#{@app_name}' for autostart" }
    rescue ex
      raise Core::Error.new(
        "Failed to register '#{@app_name}' for autostart: #{ex.message}",
        code: "AUTOSTART_REGISTER_FAILED"
      )
    end

    # Unregister the application from autostart.
    #
    # Removes the platform-specific autostart entry. No-op if not registered.
    #
    # Raises `Core::Error` if unregistration fails.
    def disable : Nil
      platform_disable
      Log.debug { "Autostart: unregistered '#{@app_name}' from autostart" }
    rescue ex
      raise Core::Error.new(
        "Failed to unregister '#{@app_name}' from autostart: #{ex.message}",
        code: "AUTOSTART_UNREGISTER_FAILED"
      )
    end

    # Check whether the application is currently registered for autostart.
    #
    # Returns `true` if an autostart entry exists for this application,
    # `false` otherwise.
    #
    # Returns `false` (and logs a warning) rather than raising if the
    # backend fails — this method is intended for UI status display and
    # must not throw.
    def enabled? : Bool
      platform_enabled?
    rescue ex
      Log.warn { "Autostart: error checking autostart status for '#{@app_name}': #{ex.message}" }
      false
    end

    # :nodoc:
    private def platform_enable(options : AutostartOptions) : Nil
      entry = ::NativeDesktop::AutostartEntry.new(
        @app_name,
        @app_path,
        options.args,
        options.minimized?,
        options.delay,
      )
      @provider.enable(entry)
    end

    # :nodoc:
    private def platform_disable : Nil
      @provider.disable(@app_name)
    end

    # :nodoc:
    private def platform_enabled? : Bool
      @provider.enabled?(@app_name)
    end
  end
end
