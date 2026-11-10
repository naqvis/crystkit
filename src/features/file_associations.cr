require "log"
require "json"
require "native_desktop"
require "../core/errors"

module CrystKit::Features
  # One file type handled by the application.
  struct FileAssociation
    include JSON::Serializable

    getter extension : String
    getter mime_type : String
    getter name : String
    getter description : String?

    def initialize(@extension : String, @mime_type : String, @name : String, @description : String? = nil)
    end
  end

  # Registers the application as an available handler for file types and
  # dispatches files opened through the operating system.
  #
  # Obtain the app-owned instance with `App#file_associations`. Registration
  # is per-user and does not replace the user's default application.
  #
  # ```
  # app.file_associations do |files|
  #   files.register(".md", "text/markdown", "Markdown Document")
  #   files.on_open { |path| puts "Opened #{path}" }
  # end
  # ```
  class FileAssociations
    # :nodoc:
    Log = ::Log.for(self)

    # :nodoc:
    abstract class Provider
      abstract def register(association : ::NativeDesktop::FileAssociation) : Nil
      abstract def unregister(association : ::NativeDesktop::FileAssociation) : Nil
    end

    # :nodoc:
    class NativeProvider < Provider
      def register(association : ::NativeDesktop::FileAssociation) : Nil
        ::NativeDesktop.file_associations.register(association)
      end

      def unregister(association : ::NativeDesktop::FileAssociation) : Nil
        ::NativeDesktop.file_associations.unregister(association)
      end
    end

    getter application_id : String
    getter application_name : String
    getter executable : Path

    @associations = {} of String => FileAssociation
    @activated_extensions = Set(String).new
    @on_open_handlers = [] of Proc(Path, Nil)
    @lock = Mutex.new

    # :nodoc:
    def initialize(
      @application_id : String,
      @application_name : String,
      @executable : Path,
      @provider : Provider = NativeProvider.new,
      @storage_file : Path? = nil,
    )
      load_persisted
    end

    # Registered file types, ordered by extension.
    def associations : Array(FileAssociation)
      @lock.synchronize { @associations.values.sort_by(&.extension) }
    end

    # Registers this application as a handler for `extension`.
    #
    # Re-registering an unchanged file type is a no-op. Replacing an existing
    # registration first removes its old MIME association; if the new
    # registration fails, CrystKit attempts to restore the previous one.
    def register(
      extension : String,
      mime_type : String,
      name : String,
      description : String? = nil,
    ) : FileAssociation
      @lock.synchronize do
        register_locked(extension, mime_type, name, description)
      end
    end

    private def register_locked(extension, mime_type, name, description) : FileAssociation
      native = build_native(extension, mime_type, name, description)
      file_type = from_native(native)
      previous = @associations[native.extension]?
      if previous && previous == file_type && @activated_extensions.includes?(native.extension)
        return previous
      end

      previous_native = previous.try { |value| to_native(value) }
      previous_activated = @activated_extensions.includes?(native.extension)
      previous_removed = false

      begin
        if previous_native && previous != file_type
          @provider.unregister(previous_native)
          previous_removed = true
        end
        @provider.register(native)
        @associations[native.extension] = file_type
        @activated_extensions << native.extension
        persist!
      rescue ex
        rollback_registration(native, previous, previous_native, previous_removed, previous_activated)
        raise Core::Error.new(
          "Failed to register file type #{native.extension.inspect}: #{ex.message}",
          code: "FILE_ASSOCIATION_REGISTER_FAILED",
        )
      end

      file_type
    end

    # Removes this application's registration for `extension`.
    #
    # Returns `false` when the extension was not registered by this feature.
    def unregister(extension : String) : Bool
      normalized = normalize_extension(extension)
      @lock.synchronize do
        file_type = @associations[normalized]?
        return false unless file_type

        @provider.unregister(to_native(file_type))
        @associations.delete(normalized)
        @activated_extensions.delete(normalized)
        begin
          persist!
        rescue ex
          @provider.register(to_native(file_type))
          @associations[normalized] = file_type
          @activated_extensions << normalized
          raise ex
        end
        true
      end
    rescue ex
      raise Core::Error.new(
        "Failed to unregister file type #{normalized.inspect}: #{ex.message}",
        code: "FILE_ASSOCIATION_UNREGISTER_FAILED",
      )
    end

    # Returns whether `extension` is registered by this feature instance.
    def registered?(extension : String) : Bool
      normalized = normalize_extension(extension)
      @lock.synchronize { @associations.has_key?(normalized) }
    end

    # Registers a handler for files opened with this application.
    #
    # Handlers run in registration order and receive a `Path`.
    def on_open(&block : Path -> Nil) : self
      @lock.synchronize { @on_open_handlers << block }
      self
    end

    # Dispatches a path supplied by the host or application lifecycle.
    #
    # Returns `false` when its extension is not registered or no handlers are
    # installed.
    def handle_open(path : String | Path) : Bool
      value = Path[path]
      normalized = normalize_extension(value.extension)
      handlers = @lock.synchronize do
        @associations.has_key?(normalized) ? @on_open_handlers.dup : [] of Proc(Path, Nil)
      end
      return false if handlers.empty?

      Log.info { "File opened: #{value}" }
      handlers.each do |handler|
        handler.call(value)
      rescue ex
        Log.error(exception: ex) { "File-open handler failed for #{value}" }
      end
      true
    end

    # Dispatches command-line file arguments whose extensions are registered.
    # Non-file options and unrelated arguments are ignored.
    def handle_arguments(arguments : Enumerable(String)) : Int32
      handled = 0
      arguments.each do |argument|
        next if argument.starts_with?('-')
        handled += 1 if handle_open(argument)
      end
      handled
    end

    # Generates document-type fragments for a macOS application bundle.
    def to_macos_plist_entries : Array(String)
      associations.map do |association|
        extension = xml(association.extension.lstrip('.'))
        name = xml(association.name)
        mime_type = xml(association.mime_type)
        <<-XML
        <dict>
          <key>CFBundleTypeName</key>
          <string>#{name}</string>
          <key>CFBundleTypeRole</key>
          <string>Viewer</string>
          <key>LSHandlerRank</key>
          <string>Alternate</string>
          <key>CFBundleTypeExtensions</key>
          <array><string>#{extension}</string></array>
          <key>CFBundleTypeMIMETypes</key>
          <array><string>#{mime_type}</string></array>
        </dict>
        XML
      end
    end

    # Generates the MIME declaration for a freedesktop desktop entry.
    def to_linux_desktop_mime : String?
      types = associations.map(&.mime_type).uniq
      "MimeType=#{types.join(";")};" unless types.empty?
    end

    private def build_native(extension, mime_type, name, description)
      ::NativeDesktop::FileAssociation.new(
        application_id: @application_id,
        application_name: @application_name,
        extension: extension,
        type_name: name,
        mime_type: mime_type,
        executable: @executable,
        description: description,
      )
    end

    private def to_native(file_type : FileAssociation)
      build_native(
        file_type.extension,
        file_type.mime_type,
        file_type.name,
        file_type.description,
      )
    end

    private def from_native(association : ::NativeDesktop::FileAssociation) : FileAssociation
      FileAssociation.new(
        association.extension,
        association.mime_type,
        association.type_name,
        association.description,
      )
    end

    private def normalize_extension(extension : String) : String
      value = extension.strip.downcase
      value.starts_with?('.') ? value : ".#{value}"
    end

    private def restore(previous : ::NativeDesktop::FileAssociation?) : Bool
      return false unless previous
      restore_association(previous)
    end

    private def restore_association(previous : ::NativeDesktop::FileAssociation) : Bool
      @provider.register(previous)
      true
    rescue ex
      Log.error(exception: ex) { "Could not restore file association #{previous.extension.inspect}" }
      false
    end

    private def rollback_registration(
      native : ::NativeDesktop::FileAssociation,
      previous : FileAssociation?,
      previous_native : ::NativeDesktop::FileAssociation?,
      previous_removed : Bool,
      previous_activated : Bool,
    ) : Nil
      begin
        @provider.unregister(native)
      rescue ex
        Log.error(exception: ex) { "Could not roll back file association #{native.extension.inspect}" }
      end

      if previous
        @associations[native.extension] = previous
      else
        @associations.delete(native.extension)
      end
      @activated_extensions.delete(native.extension)

      if previous_removed && previous_native && restore(previous_native)
        @activated_extensions << native.extension
      elsif previous_activated
        @activated_extensions << native.extension
      end
    end

    private def load_persisted : Nil
      path = @storage_file
      return unless path && File.file?(path)

      Array(FileAssociation).from_json(File.read(path)).each do |file_type|
        native = to_native(file_type)
        @associations[native.extension] = from_native(native)
      rescue ex
        Log.warn(exception: ex) { "Ignoring an invalid persisted file association" }
      end
    rescue ex
      Log.warn(exception: ex) { "Could not load file-association metadata from #{path}" }
    end

    private def persist! : Nil
      path = @storage_file
      return unless path

      Dir.mkdir_p(path.parent)
      temporary = path.parent / ".#{path.basename}.#{Process.pid}.tmp"
      begin
        File.write(temporary, @associations.values.sort_by(&.extension).to_json)
        File.rename(temporary, path)
      ensure
        File.delete?(temporary)
      end
    end

    private def xml(value : String) : String
      value.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;").gsub('\'', "&apos;")
    end
  end
end
