require "json"
require "file_utils"
require "log"
require "../core/errors"
require "../security/capability"
require "../security/scope"
require "../security/context"

require "native_desktop"

module CrystKit
  module Features
    # File entry returned by `FileSystem#list_dir`.
    #
    # Describes one child of a listed directory: its bare name, absolute path,
    # `FileType`, byte size, and last-modified time. Symlinks are reported as
    # `FileType::Symlink`.
    struct FileEntry
      # Bare file name within the listed directory (no path prefix).
      getter name : String
      # Absolute path to the entry.
      getter path : Path
      # Whether the entry is a file, directory, symlink, or unknown type.
      getter type : FileType
      # Size in bytes; `0` for directories.
      getter size : Int64
      # Last-modified timestamp.
      getter modified_at : Time

      # Creates a file entry from `File.info`-style metadata.
      def initialize(@name : String, @path : Path, @type : FileType, @size : Int64, @modified_at : Time)
      end
    end

    # Kind of filesystem entry reported by `FileSystem#list_dir`.
    enum FileType
      # A regular file.
      File
      # A directory.
      Directory
      # A symbolic link (not followed).
      Symlink
      # Anything else the platform cannot classify.
      Unknown
    end

    # File metadata returned by `FileSystem#metadata`.
    #
    # Bundles the size and the four standard timestamps plus the Unix
    # permission bits.
    struct FileMetadata
      # Size in bytes.
      getter size : Int64
      # Creation time (currently mirrors `#modified_at`).
      getter created_at : Time
      # Last-modified time.
      getter modified_at : Time
      # Last-accessed time (currently mirrors `#modified_at`).
      getter accessed_at : Time
      # Unix-style permission bits (e.g., `0o644`).
      getter permissions : Int32 # Unix-style permission bits

      # Creates a metadata value from the given size, timestamps, and
      # permission bits.
      def initialize(@size : Int64, @created_at : Time, @modified_at : Time, @accessed_at : Time, @permissions : Int32)
      end
    end

    # Secure file system operations with capability and scope enforcement.
    #
    # Application-facing API for reading, writing, copying, moving, and listing
    # files and directories. Every method is gated by two cooperating security
    # layers exposed through the injected `Security::Context`:
    #
    # 1. A *capability* (`fs:read`, `fs:write`, `fs:delete`) must be granted to
    #    the active window.
    # 2. The concrete *path* must have a persisted `Security::Permission` scope
    #    satisfying the requested permission.
    #
    # Paths are expanded with `Path#expand(home: true)` before both checks, so
    # `~`-prefixed paths resolve against the user's home directory. All errors
    # are normalised to `Core::FileSystemError` with a stable *code*.
    #
    # ```
    # fs = FileSystem.new(security_ctx)
    # fs.write_text(Path["~/notes.txt"], "hello")
    # fs.read_text(Path["~/notes.txt"]) # => "hello"
    # ```
    class FileSystem
      # :nodoc:
      @security : Security::Context

      # Creates a file system facade with the given security context
      # *context*.
      def initialize(@security : Security::Context)
      end

      # Creates a file system facade from separate *capabilities* and
      # *scopes* subsystems.
      def initialize(capabilities : Security::CapabilitySystem, scopes : Security::ScopeManager)
        @security = Security::Context.new(capabilities, scopes)
      end

      # Wraps a filesystem operation with standard error handling.
      # :nodoc:
      private def with_fs_op(operation : String, error_code : String, path : Path, &)
        abs = absolute!(path)
        yield abs
      rescue ex : File::NotFoundError
        raise Core::FileSystemError.new("File not found: #{abs}", code: "FILE_NOT_FOUND")
      rescue ex : File::AccessDeniedError
        raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
      rescue ex
        raise Core::FileSystemError.new("Failed to #{operation}: #{ex.message}", code: error_code)
      end

      # Wraps a filesystem write operation with disk-full detection.
      # :nodoc:
      private def with_fs_write(operation : String, path : Path, &)
        abs = absolute!(path)
        yield abs
      rescue ex : File::AccessDeniedError
        raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
      rescue ex : IO::Error
        if ex.os_error == Errno::ENOSPC
          raise Core::FileSystemError.new("Disk full: cannot write to #{abs}", code: "DISK_FULL")
        end
        raise Core::FileSystemError.new("Failed to #{operation}: #{ex.message}", code: "WRITE_ERROR")
      rescue ex
        raise Core::FileSystemError.new("Failed to #{operation}: #{ex.message}", code: "WRITE_ERROR")
      end

      # Read file contents as UTF-8 text.
      #
      # Requires `fs:read` capability and a read scope for *path*.
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `READ_ERROR`).
      def read_text(path : Path) : String
        check_path!("fs:read", path, Security::Permission::Read)
        with_fs_op("read_file", "READ_ERROR", path) { |abs| File.read(abs.to_s) }
      end

      # Read file contents as binary data.
      #
      # Requires `fs:read` capability and a read scope for *path*.
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `READ_ERROR`).
      def read_binary(path : Path) : Bytes
        check_path!("fs:read", path, Security::Permission::Read)
        with_fs_op("read_file", "READ_ERROR", path) { |abs| File.read(abs.to_s).to_slice }
      end

      # Opens a file for streaming reads, yielding an `IO` to the block.
      #
      # Requires `fs:read` capability and a read scope for *path*. The
      # file is closed automatically when the block returns. Use this
      # instead of `#read_text` / `#read_binary` for large files that
      # should not be loaded into memory all at once — iterate with
      # `io.each_line`, `io.read(slice)`, or `IO.copy` as needed.
      #
      # ```
      # fs.open_read(Path["~/large.log"]) do |io|
      #   io.each_line { |line| process(line) }
      # end
      # ```
      #
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `READ_ERROR`).
      def open_read(path : Path, &) : Nil
        check_path!("fs:read", path, Security::Permission::Read)
        with_fs_op("open_read", "READ_ERROR", path) do |abs|
          File.open(abs.to_s, "r") do |io|
            yield io
          end
        end
      end

      # Write UTF-8 text to a file (overwrites if exists).
      #
      # Requires `fs:write` capability and a write scope for *path*.
      # Raises `Core::FileSystemError` (code `PERMISSION_DENIED`,
      # `DISK_FULL`, or `WRITE_ERROR`).
      def write_text(path : Path, content : String) : Nil
        check_path!("fs:write", path, Security::Permission::Write)
        with_fs_write("write", path) { |abs| File.write(abs.to_s, content) }
      end

      # Write binary data to a file.
      #
      # Requires `fs:write` capability and a write scope for *path*.
      # Raises `Core::FileSystemError` (code `PERMISSION_DENIED`,
      # `DISK_FULL`, or `WRITE_ERROR`).
      def write_binary(path : Path, data : Bytes) : Nil
        check_path!("fs:write", path, Security::Permission::Write)
        with_fs_write("write", path) { |abs| File.write(abs.to_s, data) }
      end

      # Opens a file for streaming writes, yielding an `IO` to the block.
      #
      # Requires `fs:write` capability and a write scope for *path*. The
      # file is created if it does not exist and truncated if it does.
      # The file is closed (and flushed) automatically when the block
      # returns. Use this instead of `#write_text` / `#write_binary` for
      # large or incrementally-produced content.
      #
      # ```
      # fs.open_write(Path["~/output.dat"]) do |io|
      #   1000.times { io.puts "line" }
      # end
      # ```
      #
      # Raises `Core::FileSystemError` (code `PERMISSION_DENIED`,
      # `DISK_FULL`, or `WRITE_ERROR`).
      def open_write(path : Path, &) : Nil
        check_path!("fs:write", path, Security::Permission::Write)
        with_fs_write("open_write", path) do |abs|
          File.open(abs.to_s, "w") do |io|
            yield io
          end
        end
      end

      # Create a directory, optionally recursively.
      #
      # Requires `fs:write` capability and a write scope for *path*.
      # When *recursive* is `true`, creates intermediate directories as
      # needed (like `mkdir -p`); otherwise raises if the parent does not
      # exist. Raises `Core::FileSystemError` (code
      # `PERMISSION_DENIED` or `CREATE_DIR_ERROR`).
      def create_dir(path : Path, recursive : Bool = false) : Nil
        check_path!("fs:write", path, Security::Permission::Write)
        abs = absolute!(path)
        begin
          if recursive
            Dir.mkdir_p(abs.to_s)
          else
            Dir.mkdir(abs.to_s)
          end
        rescue ex : File::AccessDeniedError
          raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
        rescue ex
          raise Core::FileSystemError.new("Failed to create directory: #{ex.message}", code: "CREATE_DIR_ERROR")
        end
      end

      # Delete a file.
      #
      # Requires `fs:delete` capability and a write scope for *path*.
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `DELETE_ERROR`).
      def remove_file(path : Path) : Nil
        check_path!("fs:delete", path, Security::Permission::Write)
        with_fs_op("delete_file", "DELETE_ERROR", path) { |abs| File.delete(abs.to_s) }
      end

      # Delete a directory (must be empty unless *recursive* is `true`).
      #
      # Requires `fs:delete` capability and a write scope for *path*.
      # When *recursive* is `true`, removes the directory tree
      # recursively (like `rm -rf`). Raises `Core::FileSystemError`
      # (code `PERMISSION_DENIED` or `DELETE_ERROR`).
      def remove_dir(path : Path, recursive : Bool = false) : Nil
        check_path!("fs:delete", path, Security::Permission::Write)
        abs = absolute!(path)
        begin
          if recursive
            FileUtils.rm_rf(abs.to_s)
          else
            Dir.delete(abs.to_s)
          end
        rescue ex : File::AccessDeniedError
          raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
        rescue ex
          raise Core::FileSystemError.new("Failed to delete directory: #{ex.message}", code: "DELETE_ERROR")
        end
      end

      # Delete a file or directory to the OS trash/recycle bin.
      #
      # Requires `fs:delete` capability and a write scope for *path*.
      # Works on files, directories (recursively), and symlinks. The
      # item is moved to the platform-native trash (Finder Trash on
      # macOS, FreeDesktop.org Trash on Linux, Recycle Bin on Windows)
      # and can be restored manually by the user from there.
      #
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, `TRASH_ERROR`, or `TRASH_UNSUPPORTED`).
      def trash_delete(path : Path) : Nil
        check_path!("fs:delete", path, Security::Permission::Write)
        abs = absolute!(path)
        unless File.exists?(abs.to_s) || Dir.exists?(abs.to_s) || File.symlink?(abs.to_s)
          raise Core::FileSystemError.new("File not found: #{abs}", code: "FILE_NOT_FOUND")
        end

        ::NativeDesktop.trash.move(abs)
      rescue ex : ::NativeDesktop::TrashError
        code = case ex.code
               when :file_not_found    then "FILE_NOT_FOUND"
               when :permission_denied then "PERMISSION_DENIED"
               else                         "TRASH_ERROR"
               end
        raise Core::FileSystemError.new(ex.message || "Failed to trash #{abs}", code: code)
      rescue ex : Core::FileSystemError
        raise ex
      rescue ex : Core::SecurityError
        raise ex
      rescue ex : File::AccessDeniedError
        raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
      rescue ex
        raise Core::FileSystemError.new("Failed to trash #{abs}: #{ex.message}", code: "TRASH_ERROR")
      end

      # Copy a file or directory. Raises if destination already exists.
      #
      # Requires `fs:read` on *source* and `fs:write` on *dest* plus
      # matching scopes. Copies recursively when *source* is a
      # directory. Raises `Core::FileSystemError` (code
      # `DESTINATION_EXISTS`, `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `COPY_ERROR`).
      def copy(source : Path, dest : Path) : Nil
        check_path!("fs:read", source, Security::Permission::Read)
        check_path!("fs:write", dest, Security::Permission::Write)
        abs_src = absolute!(source)
        abs_dst = absolute!(dest)

        if File.exists?(abs_dst.to_s) || Dir.exists?(abs_dst.to_s)
          raise Core::FileSystemError.new(
            "Destination already exists: #{abs_dst}",
            code: "DESTINATION_EXISTS"
          )
        end

        begin
          FileUtils.cp_r(abs_src.to_s, abs_dst.to_s)
        rescue ex : File::NotFoundError
          raise Core::FileSystemError.new("Source not found: #{abs_src}", code: "FILE_NOT_FOUND")
        rescue ex : File::AccessDeniedError
          raise Core::FileSystemError.new("Permission denied", code: "PERMISSION_DENIED")
        rescue ex
          raise Core::FileSystemError.new("Failed to copy: #{ex.message}", code: "COPY_ERROR")
        end
      end

      # Move a file or directory. Raises if destination already exists.
      #
      # Requires `fs:write` on both *source* and *dest* plus matching
      # scopes. Raises `Core::FileSystemError` (code
      # `DESTINATION_EXISTS`, `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `MOVE_ERROR`).
      def move(source : Path, dest : Path) : Nil
        check_path!("fs:write", source, Security::Permission::Write)
        check_path!("fs:write", dest, Security::Permission::Write)
        abs_src = absolute!(source)
        abs_dst = absolute!(dest)

        if File.exists?(abs_dst.to_s) || Dir.exists?(abs_dst.to_s)
          raise Core::FileSystemError.new(
            "Destination already exists: #{abs_dst}",
            code: "DESTINATION_EXISTS"
          )
        end

        begin
          FileUtils.mv(abs_src.to_s, abs_dst.to_s)
        rescue ex : File::NotFoundError
          raise Core::FileSystemError.new("Source not found: #{abs_src}", code: "FILE_NOT_FOUND")
        rescue ex : File::AccessDeniedError
          raise Core::FileSystemError.new("Permission denied", code: "PERMISSION_DENIED")
        rescue ex
          raise Core::FileSystemError.new("Failed to move: #{ex.message}", code: "MOVE_ERROR")
        end
      end

      # List directory contents with metadata.
      #
      # Requires `fs:read` capability and a read scope for *path*.
      # Returns an array of `FileEntry` values, one per child. Entries
      # that cannot be `stat`-ed are skipped with a warn-level log entry
      # rather than aborting the whole listing. Raises
      # `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `LIST_ERROR`).
      def list_dir(path : Path) : Array(FileEntry)
        check_path!("fs:read", path, Security::Permission::Read)
        abs = absolute!(path)

        unless Dir.exists?(abs.to_s)
          raise Core::FileSystemError.new("Directory not found: #{abs}", code: "FILE_NOT_FOUND")
        end

        entries = [] of FileEntry
        begin
          Dir.each_child(abs.to_s) do |name|
            child_path = abs / name
            begin
              info = File.info(child_path.to_s, follow_symlinks: false)
              file_type = if info.symlink?
                            FileType::Symlink
                          elsif info.directory?
                            FileType::Directory
                          elsif info.file?
                            FileType::File
                          else
                            FileType::Unknown
                          end
              entries << FileEntry.new(
                name: name,
                path: child_path,
                type: file_type,
                size: info.size,
                modified_at: info.modification_time
              )
            rescue ex
              Log.warn { "FileSystem: could not stat #{child_path}: #{ex.message}" }
            end
          end
        rescue ex : File::AccessDeniedError
          raise Core::FileSystemError.new("Permission denied: #{abs}", code: "PERMISSION_DENIED")
        rescue ex
          raise Core::FileSystemError.new("Failed to list directory: #{ex.message}", code: "LIST_ERROR")
        end

        entries
      end

      # Check if a file or directory exists.
      #
      # Requires `fs:read` capability and a read scope for *path*.
      # Returns `true` for both files and directories. Raises
      # `Core::SecurityError` if the capability or scope is missing.
      def exists?(path : Path) : Bool
        check_path!("fs:read", path, Security::Permission::Read)
        abs = absolute!(path)
        File.exists?(abs.to_s) || Dir.exists?(abs.to_s)
      end

      # Read file metadata.
      #
      # Requires `fs:read` capability and a read scope for *path*.
      # Raises `Core::FileSystemError` (code `FILE_NOT_FOUND`,
      # `PERMISSION_DENIED`, or `METADATA_ERROR`).
      def metadata(path : Path) : FileMetadata
        check_path!("fs:read", path, Security::Permission::Read)
        with_fs_op("read_metadata", "METADATA_ERROR", path) do |abs|
          info = File.info(abs.to_s)
          FileMetadata.new(
            size: info.size,
            created_at: info.modification_time,
            modified_at: info.modification_time,
            accessed_at: info.modification_time,
            permissions: info.permissions.value.to_i32
          )
        end
      end

      # :nodoc:
      private def check_path!(capability : String, path : Path, permission : Security::Permission) : Nil
        @security.require_path!(capability, path, permission)
      end

      # :nodoc:
      private def absolute!(path : Path) : Path
        str = path.to_s
        raise Core::FileSystemError.new("Invalid path: path cannot be empty", code: "INVALID_PATH") if str.empty?
        path.expand(home: true)
      end
    end
  end
end
