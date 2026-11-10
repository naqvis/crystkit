require "../base"

module CrystKit
  module Plugins
    # Logging plugin bridging frontend log messages into the host `::Log`
    # subsystem.
    #
    # Messages are emitted under the `frontend` log source. An optional
    # metadata payload is appended to the message as JSON.
    #
    # Registers IPC commands:
    #   log:trace — Log a trace message
    #   log:debug — Log a debug message
    #   log:info — Log an info message
    #   log:warn — Log a warn message
    #   log:error — Log an error message
    #   log:set_level — Set the logging level for a module
    #
    # All commands require the `log:write` capability.
    class Logging < Plugin::Base
      def identifier : String
        "logging"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(log.trace log.debug log.info log.warn log.error log.set_level), "log:write")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(log:write),
          commands: %w(log.trace log.debug log.info log.warn log.error log.set_level),
          ipc: ipc,
        )
      end

      # The severity commands take a message string and an optional `JSON::Any`
      # metadata value. `log.set_level` takes a module name and a severity
      # string (parsed via `Log::Severity.parse`) and reconfigures that
      # module's logger level at runtime.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "log.trace", String, JSON::Any? do |msg, meta|
          Log.for("frontend").trace { build_msg(msg, meta) }
        end

        context.command "log.debug", String, JSON::Any? do |msg, meta|
          Log.for("frontend").debug { build_msg(msg, meta) }
        end

        context.command "log.info", String, JSON::Any? do |msg, meta|
          Log.for("frontend").info { build_msg(msg, meta) }
        end

        context.command "log.warn", String, JSON::Any? do |msg, meta|
          Log.for("frontend").warn { build_msg(msg, meta) }
        end

        context.command "log.error", String, JSON::Any? do |msg, meta|
          Log.for("frontend").error { build_msg(msg, meta) }
        end

        context.command "log.set_level", String, String do |module_name, level_str|
          level = Log::Severity.parse(level_str)
          Log.for(module_name).level = level
        end
      end

      # :nodoc: Combines a message with its optional metadata, appending the
      # metadata as JSON when present.
      private def build_msg(msg : String, meta : JSON::Any?) : String
        if meta
          "#{msg} #{meta.to_json}"
        else
          msg
        end
      end
    end
  end
end
