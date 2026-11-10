require "./spec_helper"
require "../src/features/logging"
include CrystKit::Features

def silent_config(
  level : Log::Severity = Log::Severity::Trace,
  console : Bool = false,
  log_dir : Path? = nil,
  log_file : String = "app.log",
  rotation : RotationPolicy = RotationPolicy::None,
  max_file_size : Int64 = 10_485_760_i64,
  source_location : Bool = false,
  format : LogFormat = LogFormat::Text,
  module_filters : Array(ModuleFilter) = [] of ModuleFilter,
) : LoggingConfig
  LoggingConfig.new(
    level: level,
    console: console,
    log_dir: log_dir,
    log_file: log_file,
    rotation: rotation,
    max_file_size: max_file_size,
    source_location: source_location,
    format: format,
    module_filters: module_filters,
  )
end

describe CrystKit::Features::AppLogger do
  describe "log filtering by level" do
    it "emits messages at or above the global level" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Warn))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.debug("src", "debug-msg")
      logger.info("src", "info-msg")
      logger.warn("src", "warn-msg")
      logger.error("src", "error-msg")
      captured.should_not contain("debug-msg")
      captured.should_not contain("info-msg")
      captured.should contain("warn-msg")
      captured.should contain("error-msg")
    end
    it "suppresses all messages when level is set above Error" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Fatal))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.error("src", "should-be-suppressed")
      captured.should be_empty
    end
    it "emits all messages when level is Trace" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Trace))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.trace("src", "trace-msg")
      logger.debug("src", "debug-msg")
      logger.info("src", "info-msg")
      captured.should contain("trace-msg")
      captured.should contain("debug-msg")
      captured.should contain("info-msg")
    end
  end
  describe "log filtering by module" do
    it "applies a module filter that raises the minimum level for a source" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Debug))
      logger.formatter = ->(e : LogEntry) { captured << "#{e.source}:#{e.message}"; e.message }
      logger.add_module_filter("MyApp.Noisy", Log::Severity::Error)
      logger.debug("MyApp.Noisy", "noisy-debug")
      logger.info("MyApp.Noisy", "noisy-info")
      logger.error("MyApp.Noisy", "noisy-error")
      logger.debug("MyApp.Other", "other-debug")
      captured.should_not contain("MyApp.Noisy:noisy-debug")
      captured.should_not contain("MyApp.Noisy:noisy-info")
      captured.should contain("MyApp.Noisy:noisy-error")
      captured.should contain("MyApp.Other:other-debug")
    end
    it "applies a module filter that lowers the minimum level for a source" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Warn))
      logger.formatter = ->(e : LogEntry) { captured << "#{e.source}:#{e.message}"; e.message }
      logger.add_module_filter("MyApp.Verbose", Log::Severity::Debug)
      logger.debug("MyApp.Verbose", "verbose-debug")
      logger.debug("MyApp.Other", "other-debug")
      logger.warn("MyApp.Other", "other-warn")
      captured.should contain("MyApp.Verbose:verbose-debug")
      captured.should_not contain("MyApp.Other:other-debug")
      captured.should contain("MyApp.Other:other-warn")
    end
    it "uses the most-specific (longest) matching prefix" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Debug))
      logger.formatter = ->(e : LogEntry) { captured << "#{e.source}:#{e.message}"; e.message }
      logger.add_module_filter("MyApp", Log::Severity::Warn)
      logger.add_module_filter("MyApp.HTTP", Log::Severity::Debug)
      logger.debug("MyApp.HTTP.Client", "http-debug")
      logger.debug("MyApp.Other", "other-debug")
      logger.warn("MyApp.Other", "other-warn")
      captured.should contain("MyApp.HTTP.Client:http-debug")
      captured.should_not contain("MyApp.Other:other-debug")
      captured.should contain("MyApp.Other:other-warn")
    end
    it "removes a module filter with remove_module_filter" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Debug))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.add_module_filter("MyApp", Log::Severity::Error)
      logger.remove_module_filter("MyApp")
      logger.debug("MyApp", "debug-after-removal")
      captured.should contain("debug-after-removal")
    end
    it "clears all module filters with clear_module_filters" do
      captured = [] of String
      logger = AppLogger.new(silent_config(level: Log::Severity::Debug))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.add_module_filter("A", Log::Severity::Error)
      logger.add_module_filter("B", Log::Severity::Error)
      logger.clear_module_filters
      logger.debug("A", "a-debug")
      logger.debug("B", "b-debug")
      captured.should contain("a-debug")
      captured.should contain("b-debug")
    end
    it "accepts module_filters in LoggingConfig constructor" do
      captured = [] of String
      filters = [ModuleFilter.new("Quiet", Log::Severity::Error)]
      logger = AppLogger.new(silent_config(
        level: Log::Severity::Debug,
        module_filters: filters
      ))
      logger.formatter = ->(e : LogEntry) { captured << e.message; e.message }
      logger.debug("Quiet", "quiet-debug")
      logger.error("Quiet", "quiet-error")
      captured.should_not contain("quiet-debug")
      captured.should contain("quiet-error")
    end
  end
  describe "log file write error handling" do
    it "does not raise when the log directory cannot be created" do
      SpecHelpers.with_temp_dir do |tmp|
        blocking_file = Path.new(tmp) / "blocking_file"
        File.write(blocking_file.to_s, "I am a file")
        bad_dir = blocking_file / "subdir"
        config = LoggingConfig.new(
          level: Log::Severity::Info,
          console: false,
          log_dir: bad_dir,
        )
        logger = AppLogger.new(config)
        logger.on_write_error { |_path, _ex| }
        logger.info("src", "test message")
        true.should be_true
      end
    end
    it "invokes the on_write_error callback instead of printing to STDERR" do
      SpecHelpers.with_temp_dir do |dir|
        log_path = Path.new(dir) / "app.log"
        Dir.mkdir(log_path.to_s)
        config = LoggingConfig.new(
          level: Log::Severity::Info,
          console: false,
          log_dir: Path.new(dir),
          log_file: "app.log",
        )
        logger = AppLogger.new(config)
        errors_received = [] of {Path, String}
        logger.on_write_error do |path, ex|
          errors_received << {path, ex.message || ""}
        end
        logger.info("src", "will fail to write")
        errors_received.size.should be > 0
        errors_received.first[0].to_s.should contain("app.log")
      end
    end
    it "continues logging to console even when file write fails" do
      SpecHelpers.with_temp_dir do |dir|
        log_path = Path.new(dir) / "app.log"
        Dir.mkdir(log_path.to_s)
        console_output = IO::Memory.new
        config = LoggingConfig.new(
          level: Log::Severity::Info,
          console: true,
          log_dir: Path.new(dir),
          log_file: "app.log",
        )
        logger = AppLogger.new(config, stdout: console_output)
        logger.on_write_error { |_path, _ex| }
        logger.info("src", "console-fallback-message")
        console_output.to_s.should contain("console-fallback-message")
      end
    end
    it "swallows exceptions thrown inside the on_write_error handler" do
      SpecHelpers.with_temp_dir do |dir|
        log_path = Path.new(dir) / "app.log"
        Dir.mkdir(log_path.to_s)
        config = LoggingConfig.new(
          level: Log::Severity::Info,
          console: false,
          log_dir: Path.new(dir),
          log_file: "app.log",
        )
        logger = AppLogger.new(config)
        logger.on_write_error { |_path, _ex| raise "handler error" }
        logger.info("src", "trigger error handler")
        true.should be_true
      end
    end
  end
end
