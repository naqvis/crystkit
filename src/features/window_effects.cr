require "log"
require "native_desktop"
require "../security/capability"

module CrystKit::Features
  # :nodoc:
  abstract class WindowEffectsProvider
    abstract def apply(window_ptr : Void*, config : WindowEffectsConfig) : Nil
  end

  # :nodoc:
  class NativeWindowEffectsProvider < WindowEffectsProvider
    def apply(window_ptr : Void*, config : WindowEffectsConfig) : Nil
      effects = ::NativeDesktop::WindowEffects.new(
        vibrancy: config.vibrancy?,
        material: config.material,
        mica: config.mica?,
        acrylic: config.acrylic?,
        blur_behind: config.blur_behind?,
      )
      ::NativeDesktop::Window.attach(window_ptr).apply(effects)
    end
  end

  # Configuration selecting which modern visual effects to apply to a
  # window.
  #
  # Each flag targets a platform-specific effect; flags irrelevant to
  # the current OS are ignored, so a single configuration can be
  # shared across platforms safely.
  #
  # * `vibrancy` / `material` — macOS translucency.
  # * `mica` — Windows 11 subtle background tint.
  # * `acrylic` — Windows 10/11 acrylic blur.
  # * `blur_behind` — Linux compositor blur.
  #
  # Usage:
  # ```
  # effects = CrystKit::Features::WindowEffects.new(capabilities)
  # effects.config.vibrancy = true
  # effects.config.material = :dark
  # effects.apply(window_ptr)
  # ```
  class WindowEffectsConfig
    # Enables macOS vibrancy (translucent window background blending with
    # the desktop wallpaper).
    property? vibrancy : Bool = false
    # macOS vibrancy material type.
    #
    # One of `:dark`, `:light`, `:ultra_dark`, `:sidebar`, `:window`,
    # `:hud_window`, `:menu`, `:popover`, or `:selection`. Only consulted
    # when `#vibrancy?` is `true`.
    property material : Symbol = :dark
    # Enables the Windows 11 Mica effect (a subtle, desktop-tinted
    # background). Ignored on non-Windows platforms.
    property? mica : Bool = false
    # Enables the Windows 10/11 Acrylic blur effect. Ignored on
    # non-Windows platforms.
    property? acrylic : Bool = false
    # Enables Linux compositor blur-behind (requires a compatible
    # compositor such as KWin or Mutter). Ignored on non-Linux platforms.
    property? blur_behind : Bool = false

    # Creates a configuration.
    def initialize(
      @vibrancy = false,
      @material = :dark,
      @mica = false,
      @acrylic = false,
      @blur_behind = false,
    )
    end
  end

  # Applies `WindowEffectsConfig` effects to a native window handle.
  #
  # When `#apply` is called with a platform-specific window pointer it
  # optionally checks the `window:effects` capability (when a capability
  # system was supplied at construction) before applying.
  class WindowEffects
    Log = ::Log.for(self)

    getter config : WindowEffectsConfig
    @capabilities : Security::CapabilitySystem?

    # Creates an effects applier. When *capabilities* is non-nil,
    # `#apply` requires the `window:effects` capability before
    # applying; pass `nil` to skip the capability check.
    def initialize(@config = WindowEffectsConfig.new,
                   @capabilities = nil,
                   @provider : WindowEffectsProvider = NativeWindowEffectsProvider.new)
    end

    # Applies the held effects to the native window *window_ptr*.
    #
    # A null pointer is silently ignored. When a capability system was
    # supplied at construction the `window:effects` capability is
    # required, raising `Core::SecurityError` on denial.
    def apply(window_ptr : Void*) : Nil
      return if window_ptr.null?

      cap = @capabilities
      if cap
        cap.require!("window:effects")
      end

      return unless config.vibrancy? || config.mica? || config.acrylic? || config.blur_behind?

      @provider.apply(window_ptr, config)
    end
  end
end
