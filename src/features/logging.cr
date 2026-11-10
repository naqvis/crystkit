require "log"
require "json"
require "../core/errors"

module CrystKit
  module Features
    # Policy that selects when a log file is rotated.
    #
    # `None` disables rotation entirely (the active file grows without
    # bound). `BySize` rotates when the file would exceed
    # `LoggingConfig#max_file_size` bytes; `ByDate` rotates once per UTC
    # day.
    enum RotationPolicy
      # Never rotate; the log file grows indefinitely.
      None
      # Rotate when the next write would exceed `LoggingConfig#max_file_size`.
      BySize
      # Rotate once per UTC day, the first time a write occurs that day.
      ByDate
    end

    # Built-in log output formats.
    #
    # Requirement 22.11
    enum LogFormat
      # Human-readable text: "2024-01-01T00:00:00Z [INFO ] [source] message key=value"
      Text
      # Machine-readable JSON: {"timestamp":...,"level":...,"source":...,"message":...,"data":{...}}
      JSON
    end

    # Captures the source code location of a log call site.
    #
    # Requirement 22.8
    struct SourceLocation
      # The source file path as reported by `__FILE__`.
      getter file : String
      # The 1-based line number reported by `__LINE__`.
      getter line : Int32
      # The enclosing method name, or an empty string when unavailable.
      getter method : String

      # Creates a source location from the values captured at the call site.
      #
      # Application code does not normally construct `SourceLocation` by hand;
      # the `log_info`, `log_error`, ... macro helpers populate it from
      # compiler intrinsics.
      def initialize(@file : String, @line : Int32, @method : String)
      end

      # Renders `file:line` and, when *method* is non-empty, `" in method"`.
      def to_s(io : IO) : Nil
        io << file << ":" << line
        io << " in " << method unless method.empty?
      end
    end

    # Defines a filter rule for a specific source/module.
    #
    # Requirement 22.10
    struct ModuleFilter
      # The source/module name prefix to match (e.g. "MyApp.HTTP").
      getter source : String
      # Minimum severity required for messages from this source to pass.
      getter level : Log::Severity

      # Creates a filter rule for *source* that admits messages only at
      # or above *level*.
      #
      # Matching is by `String#starts_with?` against `LogEntry#source`; when
      # multiple filters match, the one with the longest *source* prefix wins.
      def initialize(@source : String, @level : Log::Severity)
      end
    end

    # Configuration for the logging system
    struct LoggingConfig
      # Global minimum severity below which messages are dropped before
      # per-module filters run.
      property level : Log::Severity
      # Rotation policy consulted on every file write; see `RotationPolicy`.
      property rotation : RotationPolicy
      # Maximum size in bytes the log file may reach before rotation, used
      # only when `#rotation == RotationPolicy::BySize`.
      property max_file_size : Int64
      # Directory where log files are written. When `nil`, no file backend
      # is configured regardless of the other file-related properties.
      property log_dir : Path?
      # Base filename (no directory) of the active log file inside
      # `#log_dir`; rotated files keep this stem and carry a timestamp.
      property log_file : String
      # When `true`, mirror every emitted entry to `STDOUT` (or `STDERR`
      # for `WARN`/`ERROR`).
      property? console : Bool
      # When `true`, include `SourceLocation` information in the text/JSON
      # output. Has no effect on entries whose `LogEntry#location` is `nil`.
      property? source_location : Bool
      # Built-in output format for entries without a custom formatter.
      property format : LogFormat
      # Per-module level overrides. A message whose source starts with a
      # `ModuleFilter#source` string uses that filter's level instead of the
      # global level. When multiple filters match, the most-specific (longest)
      # prefix wins.
      #
      # Requirement 22.10
      property module_filters : Array(ModuleFilter)

      # Creates a configuration bag with sensible production defaults.
      #
      # Defaults: `Info` level, no rotation, 10 MB rotation ceiling, no
      # log directory (i.e. console-only), `"app.log"` filename, console
      # enabled, source location disabled, text format, no module filters.
      def initialize(
        @level = Log::Severity::Info,
        @rotation = RotationPolicy::None,
        @max_file_size = 10_485_760_i64, # 10 MB
        @log_dir = nil,
        @log_file = "app.log",
        @console = true,
        @source_location = false,
        @format = LogFormat::Text,
        @module_filters : Array(ModuleFilter) = [] of ModuleFilter,
      )
      end
    end

    # A structured log entry with optional key-value metadata and source location.
    struct LogEntry
      # UTC timestamp at which the entry was emitted.
      getter timestamp : Time
      # Severity of the entry; compared against filters and rendered in
      # the textual output as an uppercased 5-wide tag.
      getter level : Log::Severity
      # Logical source name (e.g. "MyApp.HTTP.Client"); empty string means
      # "unattributed". Matched against `ModuleFilter#source` prefixes.
      getter source : String
      # The human-facing message text.
      getter message : String
      # Structured key-value metadata attached at the call site.
      getter data : Hash(String, String)
      # Optional source location captured at the call site; rendered into
      # both text and JSON output when set (and `LoggingConfig#source_location?`
      # is true for built-in text output).
      getter location : SourceLocation?

      # Creates an entry from the components captured at a call site.
      #
      # *timestamp* is typically `Time.utc`. *data* defaults to an empty hash.
      # *location* is `nil` unless the macro helpers (`log_info`, ...) injected
      # a `SourceLocation`.
      def initialize(
        @timestamp : Time,
        @level : Log::Severity,
        @source : String,
        @message : String,
        @data : Hash(String, String) = {} of String => String,
        @location = nil,
      )
      end

      # Default text representation: timestamp [LEVEL] [source] (file:line in method) message key=value
      def to_s(io : IO) : Nil
        io << timestamp.to_rfc3339
        io << " [" << level.to_s.upcase << "]"
        io << " [" << source << "]" unless source.empty?
        if loc = location
          io << " (" << loc << ")"
        end
        io << " " << message
        data.each { |k, v| io << " " << k << "=" << v } unless data.empty?
      end

      # Serialize the entry to a JSON string.
      #
      # Requirement 22.11 (JSON format support)
      def to_json_string : String
        String.build do |string|
          string << %[{"timestamp":"] << timestamp.to_rfc3339 << %["]
          string << %[,"level":"] << level.to_s.upcase << %["]
          string << %[,"source":"] << source.gsub('"', %[\\"]) << %["]
          if loc = location
            string << %[,"file":"] << loc.file.gsub('"', %[\\"]) << %["]
            string << %[,"line":] << loc.line
            string << %[,"method":"] << loc.method.gsub('"', %[\\"]) << %["]
          end
          string << %[,"message":"] << message.gsub('"', %[\\"]) << %["]
          unless data.empty?
            string << %[,"data":{]
            first = true
            data.each do |k, v|
              string << "," unless first
              first = false
              string << %["] << k.gsub('"', %[\\"]) << %[":]
              string << %["] << v.gsub('"', %[\\"]) << %["]
            end
            string << "}"
          end
          string << "}"
        end
      end
    end

    # Wraps Crystal's Log module to provide structured logging with file rotation,
    # console output, key-value pair support, source location capture, and
    # custom/built-in formatters.
    class AppLogger
      @config : LoggingConfig
      @backends : Array(Log::Backend)
      @file_backend : Log::IOBackend?
      @current_log_file : Path?
      @current_file_size : Int64
      @current_date : String?
      @custom_formatter : (LogEntry -> String)?
      # Optional callback invoked when a file write error occurs.
      # Receives the file path and the exception. When nil, errors are printed
      # to STDERR.
      @write_error_handler : (Path, Exception -> Nil)?
      @stdout : IO

      # Creates a logger configured by *config* and writing console output to
      # *stdout*.
      #
      # *stdout* is the sink used for non-warning console output; warnings and
      # errors always go to `STDERR` regardless.
      def initialize(@config = LoggingConfig.new, @stdout = STDOUT)
        @backends = [] of Log::Backend
        @file_backend = nil
        @current_log_file = nil
        @current_file_size = 0_i64
        @current_date = nil
        @custom_formatter = nil
        @write_error_handler = nil
        setup_backends
      end

      # Register a custom handler that is called whenever a log file write
      # error occurs. The handler receives the target file path and the
      # exception. Logging continues to other backends (e.g. console) even
      # when the file write fails.
      def on_write_error(&handler : Path, Exception -> Nil) : Nil
        @write_error_handler = handler
      end

      # Set a custom log formatter proc. When set, this overrides the built-in
      # text/JSON formats configured via LoggingConfig#format.
      def formatter=(@custom_formatter : (LogEntry -> String)?) : Nil
      end

      # Emit a TRACE level message with optional structured data.
      #
      # Requirement 22.9 (structured key-value pairs)
      def trace(source : String, message : String, **data) : Nil
        kv = {} of String => String
        data.each { |k, v| kv[k.to_s] = v.to_s }
        log(Log::Severity::Trace, source, message, kv)
      end

      # Emit a DEBUG level message with optional structured data.
      def debug(source : String, message : String, **data) : Nil
        kv = {} of String => String
        data.each { |k, v| kv[k.to_s] = v.to_s }
        log(Log::Severity::Debug, source, message, kv)
      end

      # Emit an INFO level message with optional structured data.
      def info(source : String, message : String, **data) : Nil
        kv = {} of String => String
        data.each { |k, v| kv[k.to_s] = v.to_s }
        log(Log::Severity::Info, source, message, kv)
      end

      # Emit a WARN level message with optional structured data.
      def warn(source : String, message : String, **data) : Nil
        kv = {} of String => String
        data.each { |k, v| kv[k.to_s] = v.to_s }
        log(Log::Severity::Warn, source, message, kv)
      end

      # Emit an ERROR level message with optional structured data.
      def error(source : String, message : String, **data) : Nil
        kv = {} of String => String
        data.each { |k, v| kv[k.to_s] = v.to_s }
        log(Log::Severity::Error, source, message, kv)
      end

      # Emit a log message at the given level with a hash of structured data.
      # Optionally pass an explicit *location*; when nil and
      # `config.source_location` is true the caller should supply one via the
      # macro-based helpers below.
      def log(level : Log::Severity, source : String, message : String,
              data : Hash(String, String) = {} of String => String,
              location : SourceLocation? = nil) : Nil
        return unless passes_filter?(level, source)

        entry = LogEntry.new(
          timestamp: Time.utc,
          level: level,
          source: source,
          message: message,
          data: data,
          location: location
        )

        formatted = format_entry(entry)
        write_to_backends(formatted, level)
      end

      # Add a per-module level filter at runtime.
      # Messages whose source starts with *source_prefix* must be at or above
      # *level* to be emitted. The most-specific (longest) matching prefix wins.
      def add_module_filter(source_prefix : String, level : Log::Severity) : Nil
        @config.module_filters << ModuleFilter.new(source_prefix, level)
      end

      # Remove all module filters whose source prefix equals *source_prefix*.
      def remove_module_filter(source_prefix : String) : Nil
        @config.module_filters.reject! { |filter| filter.source == source_prefix }
      end

      # Clear all per-module filters.
      def clear_module_filters : Nil
        @config.module_filters.clear
      end

      # Reconfigure the logger at runtime (e.g. change level or rotation).
      def reconfigure(config : LoggingConfig) : Nil
        @config = config
        teardown_backends
        setup_backends
      end

      # Close all backends and release file handles.
      def close : Nil
        teardown_backends
      end

      # Format a `LogEntry` using the custom formatter if set, otherwise the
      # built-in format specified by `config.format` (Text or JSON).
      def format_entry(entry : LogEntry) : String
        if formatter = @custom_formatter
          return formatter.call(entry)
        end

        case @config.format
        when LogFormat::JSON
          entry.to_json_string
        else
          # Default text format
          String.build do |string|
            # Requirement 22.6: timestamp
            string << entry.timestamp.to_rfc3339
            # Requirement 22.7: log level
            string << " [" << entry.level.to_s.upcase.ljust(5) << "]"
            # source name
            string << " [" << entry.source << "]" unless entry.source.empty?
            # Requirement 22.8: source location (file:line in method)
            if @config.source_location?
              if loc = entry.location
                string << " (" << loc << ")"
              end
            end
            # message
            string << " " << entry.message
            # Requirement 22.9: structured key-value pairs
            entry.data.each { |k, v| string << " " << k << "=" << v } unless entry.data.empty?
          end
        end
      end

      # :nodoc:
      private def write_to_backends(formatted : String, level : Log::Severity) : Nil
        # Console output
        if @config.console?
          io = level >= Log::Severity::Warn ? STDERR : @stdout
          io.puts(formatted)
        end

        # File output with rotation
        if dir = @config.log_dir
          write_to_file(dir, formatted)
        end
      end

      # :nodoc:
      private def write_to_file(dir : Path, formatted : String) : Nil
        line = formatted + "\n"
        bytes = line.bytesize.to_i64

        case @config.rotation
        when RotationPolicy::BySize
          maybe_rotate_by_size(dir, bytes)
        when RotationPolicy::ByDate
          maybe_rotate_by_date(dir)
        else
          ensure_log_file(dir)
        end

        if path = @current_log_file
          begin
            File.open(path, "a", &.print(line))
            @current_file_size += bytes
          rescue ex
            # Requirement 22.12: handle write errors gracefully – never raise,
            # always continue. Invoke the registered error handler if present,
            # otherwise fall back to STDERR so the application keeps running.
            handle_write_error(path, ex)
          end
        end
      end

      # Dispatch a file-write error to the registered handler or STDERR.
      # :nodoc:
      private def handle_write_error(path : Path, ex : Exception) : Nil
        if handler = @write_error_handler
          begin
            handler.call(path, ex)
          rescue
            # Swallow errors from the error handler itself to stay non-raising.
          end
        else
          STDERR.puts "AppLogger: failed to write to log file '#{path}': #{ex.message}"
        end
      end

      # Determine whether a message at *level* from *source* should be emitted.
      # :nodoc:
      private def passes_filter?(level : Log::Severity, source : String) : Bool
        best : ModuleFilter? = nil
        @config.module_filters.each do |filter|
          next unless source.starts_with?(filter.source)
          if (b = best).nil? || filter.source.size > b.source.size
            best = filter
          end
        end

        if matched = best
          level >= matched.level
        else
          level >= @config.level
        end
      end

      # :nodoc:
      private def ensure_log_file(dir : Path) : Nil
        return if @current_log_file

        begin
          Dir.mkdir_p(dir.to_s)
        rescue ex
          handle_write_error(dir / @config.log_file, ex)
          return
        end

        path = dir / @config.log_file
        @current_log_file = path
        @current_file_size = File.exists?(path) ? File.size(path).to_i64 : 0_i64
      end

      # :nodoc:
      private def maybe_rotate_by_size(dir : Path, incoming_bytes : Int64) : Nil
        ensure_log_file(dir)
        return unless path = @current_log_file
        return if @current_file_size + incoming_bytes <= @config.max_file_size

        rotate_file(dir, path)
      end

      # :nodoc:
      private def maybe_rotate_by_date(dir : Path) : Nil
        today = Time.utc.to_s("%Y-%m-%d")
        if @current_date != today
          if path = @current_log_file
            rotate_file(dir, path)
          end
          @current_date = today
        end
        ensure_log_file(dir)
      end

      # :nodoc:
      private def rotate_file(dir : Path, path : Path) : Nil
        timestamp = Time.utc.to_s("%Y%m%d_%H%M%S")
        base = Path.new(@config.log_file).stem
        ext = Path.new(@config.log_file).extension
        rotated = dir / "#{base}_#{timestamp}#{ext}"

        begin
          File.rename(path.to_s, rotated.to_s) if File.exists?(path.to_s)
        rescue ex
          handle_write_error(path, ex)
        end

        @current_log_file = path
        @current_file_size = 0_i64
      end

      # :nodoc:
      private def setup_backends : Nil
        @current_date = Time.utc.to_s("%Y-%m-%d") if @config.rotation == RotationPolicy::ByDate
      end

      # :nodoc:
      private def teardown_backends : Nil
        @current_log_file = nil
        @current_file_size = 0_i64
      end
    end

    # Convenience macros that automatically capture source location, injecting
    # `__FILE__`, `__LINE__`, and `__DIR__` so callers don't pass them manually.
    #
    # Requirement 22.8
    macro log_trace(logger, source, message, **data)
      {{logger}}.log(
        ::Log::Severity::Trace, {{source}}, {{message}},
        {{data}}.to_h.transform_values(&.to_s),
        ::CrystKit::Features::SourceLocation.new(__FILE__, __LINE__, "")
      )
    end

    macro log_debug(logger, source, message, **data)
      {{logger}}.log(
        ::Log::Severity::Debug, {{source}}, {{message}},
        {{data}}.to_h.transform_values(&.to_s),
        ::CrystKit::Features::SourceLocation.new(__FILE__, __LINE__, "")
      )
    end

    macro log_info(logger, source, message, **data)
      {{logger}}.log(
        ::Log::Severity::Info, {{source}}, {{message}},
        {{data}}.to_h.transform_values(&.to_s),
        ::CrystKit::Features::SourceLocation.new(__FILE__, __LINE__, "")
      )
    end

    macro log_warn(logger, source, message, **data)
      {{logger}}.log(
        ::Log::Severity::Warn, {{source}}, {{message}},
        {{data}}.to_h.transform_values(&.to_s),
        ::CrystKit::Features::SourceLocation.new(__FILE__, __LINE__, "")
      )
    end

    macro log_error(logger, source, message, **data)
      {{logger}}.log(
        ::Log::Severity::Error, {{source}}, {{message}},
        {{data}}.to_h.transform_values(&.to_s),
        ::CrystKit::Features::SourceLocation.new(__FILE__, __LINE__, "")
      )
    end
  end
end
