require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../security/context"

module CrystKit::Features
  # :nodoc:
  abstract class DialogProvider
    abstract def open_file(options : OpenFileOptions) : String?
    abstract def open_files(options : OpenFileOptions) : Array(String)
    abstract def save_file(options : SaveFileOptions) : String?
    abstract def select_folder(options : FolderOptions) : String?
    abstract def message(title : String, message : String, kind : Int32) : Bool
    abstract def confirm(title : String, message : String) : Bool
  end

  # :nodoc:
  class NativeDialogProvider < DialogProvider
    private def filters(values)
      values.map { |name, extensions| ::NativeDesktop::FileFilter.new(name, extensions) }
    end

    def message(title, message, kind) : Bool
      native_kind = ::NativeDesktop::MessageKind.from_value?(kind) || ::NativeDesktop::MessageKind::Info
      ::NativeDesktop.dialogs.message(title, message, native_kind)
      true
    end

    def confirm(title, message) : Bool
      ::NativeDesktop.dialogs.confirm(title, message)
    end
  end

  # A file-type filter entry shown in open/save dialogs.
  #
  # Each filter pairs a user-visible *name* (e.g., `"Image files"`)
  # with the list of *extensions* (without the leading dot, e.g.,
  # `["png", "jpg"]`) the backend restricts the selection to.
  struct FileFilter
    # User-visible label for the filter, shown in the dialog's file-type dropdown.
    getter name : String
    # File extensions (without dots) matched by this filter.
    getter extensions : Array(String)

    # Creates a filter from a display *name* and its *extensions*.
    def initialize(@name : String, @extensions : Array(String))
    end
  end

  # Options for `FileDialog#open_file` and `#open_files`.
  struct OpenFileOptions
    # Dialog title bar text, or `nil` for the platform default.
    property title : String?
    # Initial directory the dialog opens in, or `nil` for the platform default.
    property default_path : Path?
    # File-type filters shown in the dialog's dropdown.
    property filters : Array(FileFilter)
    # When `true`, allow selecting multiple files (used by `#open_files`).
    property? multiple : Bool
    property owner : Void*?
    property accept_label : String?
    property? show_hidden : Bool

    # Creates open-file options with optional *title*, *default_path*,
    # *filters*, and a *multiple* flag.
    def initialize(
      @title = nil,
      @default_path = nil,
      @filters = [] of FileFilter,
      @multiple = false,
      @owner = nil,
      @accept_label = nil,
      @show_hidden = false,
    )
    end
  end

  # Options for `FileDialog#save_file`.
  struct SaveFileOptions
    # Dialog title bar text, or `nil` for the platform default.
    property title : String?
    # Initial directory the dialog opens in, or `nil` for the platform default.
    property default_path : Path?
    # Suggested file name pre-filled in the save box, or `nil` for none.
    property default_name : String?
    # File-type filters shown in the dialog's dropdown.
    property filters : Array(FileFilter)
    property owner : Void*?
    property accept_label : String?
    property default_extension : String?
    property? show_hidden : Bool
    property? can_create_directories : Bool
    property? confirm_overwrite : Bool

    # Creates save-file options with optional *title*, *default_path*,
    # *default_name*, and *filters*.
    def initialize(
      @title = nil,
      @default_path = nil,
      @default_name = nil,
      @filters = [] of FileFilter,
      @owner = nil,
      @accept_label = nil,
      @default_extension = nil,
      @show_hidden = false,
      @can_create_directories = true,
      @confirm_overwrite = true,
    )
    end
  end

  # Options for `FileDialog#select_folder`.
  struct FolderOptions
    # Dialog title bar text, or `nil` for the platform default.
    property title : String?
    # Initial directory the dialog opens in, or `nil` for the platform default.
    property default_path : Path?
    property owner : Void*?
    property accept_label : String?
    property? show_hidden : Bool
    property? can_create_directories : Bool

    # Creates folder-picking options with optional *title* and *default_path*.
    def initialize(
      @title = nil,
      @default_path = nil,
      @owner = nil,
      @accept_label = nil,
      @show_hidden = false,
      @can_create_directories = true,
    )
    end
  end

  class NativeDialogProvider
    def open_file(options : OpenFileOptions) : String?
      native = ::NativeDesktop::OpenDialogOptions.new(
        title: options.title,
        directory: options.default_path,
        filters: filters(options.filters.map { |filter| {filter.name, filter.extensions} }),
        owner: options.owner,
        accept_label: options.accept_label,
        show_hidden: options.show_hidden?,
      )
      ::NativeDesktop.dialogs.open_file(native).try(&.to_s)
    end

    def open_files(options : OpenFileOptions) : Array(String)
      native = ::NativeDesktop::OpenDialogOptions.new(
        title: options.title,
        directory: options.default_path,
        filters: filters(options.filters.map { |filter| {filter.name, filter.extensions} }),
        owner: options.owner,
        accept_label: options.accept_label,
        show_hidden: options.show_hidden?,
      )
      ::NativeDesktop.dialogs.open_files(native).map(&.to_s)
    end

    def save_file(options : SaveFileOptions) : String?
      native = ::NativeDesktop::SaveDialogOptions.new(
        title: options.title,
        directory: options.default_path,
        suggested_name: options.default_name,
        filters: filters(options.filters.map { |filter| {filter.name, filter.extensions} }),
        owner: options.owner,
        accept_label: options.accept_label,
        default_extension: options.default_extension,
        show_hidden: options.show_hidden?,
        can_create_directories: options.can_create_directories?,
        confirm_overwrite: options.confirm_overwrite?,
      )
      ::NativeDesktop.dialogs.save_file(native).try(&.to_s)
    end

    def select_folder(options : FolderOptions) : String?
      native = ::NativeDesktop::FolderDialogOptions.new(
        title: options.title,
        directory: options.default_path,
        owner: options.owner,
        accept_label: options.accept_label,
        show_hidden: options.show_hidden?,
        can_create_directories: options.can_create_directories?,
      )
      ::NativeDesktop.dialogs.select_folder(native).try(&.to_s)
    end
  end

  # Native file dialog integration with security scope grants.
  #
  # `FileDialog` wraps the platform's open/save/folder pickers. Every
  # path-returning method automatically persists a `Security::Permission`
  # scope for the selected path so subsequent `FileSystem` operations do
  # not need a separate permission prompt. All file-selection methods
  # require the `dialog:open` or `dialog:save` capability via the
  # injected `Security::Context`.
  #
  # For message boxes and confirmation prompts, use `MessageDialog`
  # instead — those operations do not require a security context.
  #
  # ```
  # dialog = FileDialog.new(security_ctx)
  # path = dialog.open_file(title: "Open document")
  # ```
  class FileDialog
    # Maximum number of files accepted by `#open_files` before rejection.
    MAX_MULTIPLE_FILES = 1000
    # Maximum length of a `SaveFileOptions#default_name` string.
    MAX_DEFAULT_NAME_LEN = 255
    # Maximum length of a `*Options#default_path` string.
    MAX_DEFAULT_PATH_LEN = 4096

    # Creates a dialog controller bound to *security* and an optional
    # *backend*.
    #
    # *security* is consulted for `dialog:open` / `dialog:save`
    # capabilities and is used to persist path scopes for selected
    # files. *backend* defaults to the platform's current native
    # dialog backend and is injectable primarily for tests.
    def initialize(
      @security : Security::Context,
      @provider : DialogProvider = NativeDialogProvider.new,
    )
    end

    # Show an open-file dialog and return the selected path.
    #
    # Requires the `dialog:open` capability. When the user selects a
    # file. Returns `nil` if the user cancels.
    #
    # Raises `Core::Error` (code `PATH_TOO_LONG`) if
    # `options.default_path` exceeds `MAX_DEFAULT_PATH_LEN`.
    def open_file(options = OpenFileOptions.new) : Path?
      validate_options!(options)
      @security.require!("dialog:open")
      result = @provider.open_file(options)
      result.try { |path| Path[path] }
    end

    # Show a multi-select open-file dialog and return the selected paths.
    #
    # Requires the `dialog:open` capability. Returns an empty
    # array if the user cancels.
    #
    # Raises `Core::Error` if the number of selected files
    # exceeds `MAX_MULTIPLE_FILES`, or `PATH_TOO_LONG` if
    # `options.default_path` exceeds `MAX_DEFAULT_PATH_LEN`.
    def open_files(options = OpenFileOptions.new) : Array(Path)
      validate_options!(options)
      @security.require!("dialog:open")
      results = @provider.open_files(options)
      raise Core::Error.new("Too many files: #{results.size} (max #{MAX_MULTIPLE_FILES})") if results.size > MAX_MULTIPLE_FILES
      results.map { |result_path| Path[result_path] }
    end

    # Show a save-file dialog and return the chosen path.
    #
    # Requires the `dialog:save` capability. Returns `nil` if
    # the user cancels.
    #
    # Raises `Core::Error` (code `NAME_TOO_LONG`) if
    # `options.default_name` exceeds `MAX_DEFAULT_NAME_LEN`, or
    # `PATH_TOO_LONG` if `options.default_path` exceeds
    # `MAX_DEFAULT_PATH_LEN`.
    def save_file(options = SaveFileOptions.new) : Path?
      validate_save_options!(options)
      @security.require!("dialog:save")
      result = @provider.save_file(options)
      result.try { |path| Path[path] }
    end

    # Show a folder-picker dialog and return the selected directory.
    #
    # Requires the `dialog:open` capability. Returns `nil` if
    # the user cancels.
    #
    # Raises `Core::Error` (code `PATH_TOO_LONG`) if
    # `options.default_path` exceeds `MAX_DEFAULT_PATH_LEN`.
    def select_folder(options = FolderOptions.new) : Path?
      validate_folder_options!(options)
      @security.require!("dialog:open")
      result = @provider.select_folder(options)
      result.try { |path| Path[path] }
    end

    # :nodoc:
    private def validate_options!(options)
      if path = options.default_path
        raise Core::Error.new("Default path exceeds maximum length of #{MAX_DEFAULT_PATH_LEN} characters", code: "PATH_TOO_LONG") if path.to_s.size > MAX_DEFAULT_PATH_LEN
      end
    end

    # :nodoc:
    private def validate_save_options!(options)
      if name = options.default_name
        raise Core::Error.new("Default file name exceeds maximum length of #{MAX_DEFAULT_NAME_LEN} characters", code: "NAME_TOO_LONG") if name.size > MAX_DEFAULT_NAME_LEN
      end
      validate_options!(options)
    end

    # :nodoc:
    private def validate_folder_options!(options)
      if path = options.default_path
        raise Core::Error.new("Default path exceeds maximum length of #{MAX_DEFAULT_PATH_LEN} characters", code: "PATH_TOO_LONG") if path.to_s.size > MAX_DEFAULT_PATH_LEN
      end
    end
  end
end
