require "file_utils"

module CrystKit
  module Features
    # Copies source icons to platform output directories.
    #
    # Developers provide correctly-sized, correctly-formatted icon files for
    # the platforms they target, and the manager copies them into the output
    # directory layout expected by the platform packaging step. It performs
    # *no* resizing, format conversion, or colour-space manipulation.
    #
    # The manager understands a list of *source icons* (file paths) and groups
    # them by extension so callers can locate the variant bound for a given
    # platform (e.g. `.icns` on macOS, `.ico` on Windows, `.png` on Linux).
    #
    # ```
    # mgr = CrystKit::Features::IconManager.new(["app.icns", "app.ico", "app.png"])
    # dests = mgr.convert_for_platform("macos", "build/icons")
    # mgr.best_icon # => "app.icns" (first existing source)
    # ```
    class IconManager
      # The list of source icon file paths the manager was constructed with,
      # in priority order.
      #
      # `#best_icon` returns the first existing entry from this list, so
      # callers should order it from most-preferred to least.
      getter source_icons : Array(String)

      # Creates an icon manager bound to *source_icons*.
      #
      # The array is retained by reference; mutating it after construction
      # affects subsequent `#convert_for_platform` and `#best_icon` calls. An
      # empty list is allowed — both methods become no-ops returning empty
      # results.
      def initialize(@source_icons : Array(String) = [] of String)
      end

      # Copies each existing source icon into *output_dir*, returning a
      # mapping of file extension to destination path.
      #
      # *output_dir* is created (recursively) if missing. Source files that do
      # not exist on disk are silently skipped, allowing declarative lists such
      # as `["app.icns", "app.ico", "app.png"]` where only the relevant subset
      # exists per build. Each copied file preserves its basename; the returned
      # hash is keyed by `File.extname(icon)` so callers can locate the
      # platform-specific variant (e.g. `results[".icns"]`).
      #
      # *target* is currently informational.
      def convert_for_platform(target : String, output_dir : String) : Hash(String, String)
        results = {} of String => String

        Dir.mkdir_p(output_dir)
        source_icons.each do |icon|
          next unless File.exists?(icon)
          dest = File.join(output_dir, File.basename(icon))
          File.copy(icon, dest)
          results[File.extname(icon)] = dest
        end

        results
      end

      # Returns the path of the first existing source icon, or `nil` if none
      # of the configured sources resolve.
      #
      # *min_size* is reserved for a future implementation that prefers a
      # particular pixel size; currently it is ignored and the first existing
      # source is returned regardless of size.
      def best_icon(min_size : Int32 = 128) : String?
        source_icons.find { |i| File.exists?(i) }
      end
    end
  end
end
