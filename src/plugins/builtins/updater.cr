require "../base"
require "../../features/updater"

module CrystKit
  module Plugins
    # Builtin plugin that implements application self-update: check, download,
    # install, and rollback.
    #
    # Configured from its per-plugin config slice: `current_version`,
    # `update_url`, and `channel` (`stable`, `beta`, `dev`, defaulting to
    # `stable`). Progress and lifecycle transitions are surfaced to the
    # frontend via four events. Install produces a swap script path that the
    # host is expected to run after exit to atomically replace the binary.
    #
    # Registers IPC commands:
    #   updater:check — Check for available updates
    #   updater:download — Download the available update
    #   updater:install — Install the downloaded update
    #   updater:status — Get current update status
    #   updater:rollback — Roll back to a previous version
    #
    # Emits events: `updater.available`, `updater.progress`,
    # `updater.downloaded`, `updater.error`
    #
    # Required capability: `updater:manage`
    #
    # `updater.download` raises `Core::Error` (code `NO_UPDATE`) if no
    # update was found, and `updater.install` raises (code `NO_PACKAGE`) if no
    # update was downloaded. `updater.rollback` accepts an optional target
    # version (passing `nil` rolls back to the previous version).
    #
    # ```
    # app.plugin(CrystKit::Plugins::Updater.new)
    # ```
    class Updater < Plugin::Base
      # The auto-updater feature, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! updater : Features::AutoUpdater

      # The most recently discovered `UpdateInfo`, set by `updater.check` and
      # the `on_update_available` callback. `updater.download` reads it.
      @update_info : Features::UpdateInfo?

      # The path of the last downloaded update package, set by the
      # `on_download_complete` callback. `updater.install` reads it.
      @package_path : Path?

      # Returns the unique plugin identifier `"updater"`.
      def identifier : String
        "updater"
      end

      # Returns the metadata contract gating every updater command behind the
      # `updater:manage` capability and declaring the four lifecycle events.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(updater.check updater.download updater.install updater.status updater.rollback), "updater:manage")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(updater:manage),
          commands: %w(updater.check updater.download updater.install updater.status updater.rollback),
          events: %w(updater.available updater.progress updater.downloaded updater.error),
          ipc: ipc,
        )
      end

      # Registers the IPC commands and wires update callbacks.
      #
      # Reads `current_version` (default `"0.1.0"`), `update_url` (default
      # `https://updates.example.com`), and `channel` (default `stable`) from
      # `context.config`. `updater.check` returns the update info or `nil`
      # when current.
      def initialize_plugin(context : Plugin::Context) : Nil
        config = context.config
        version = config["current_version"]?.try(&.as_s) || "0.1.0"
        url = config["update_url"]?.try(&.as_s) || "https://updates.example.com"
        channel_str = config["channel"]?.try(&.as_s) || "stable"

        channel = case channel_str
                  when "beta" then Features::UpdateChannel::Beta
                  when "dev"  then Features::UpdateChannel::Dev
                  else             Features::UpdateChannel::Stable
                  end

        @updater = u = Features::AutoUpdater.new(version, url, channel)

        u.on_update_available do |info|
          @update_info = info
          context.emit("updater.available", context.app.coerce_to_json({
            "version"       => info.version,
            "release_notes" => info.release_notes,
            "size"          => info.size,
            "channel"       => info.channel,
          }))
        end

        u.on_download_progress do |pct|
          context.emit("updater.progress", context.app.coerce_to_json({"percent" => pct}))
        end

        u.on_download_complete do |path|
          @package_path = path
          context.emit("updater.downloaded", context.app.coerce_to_json({"path" => path.to_s}))
        end

        u.on_error do |ex|
          context.emit("updater.error", context.app.coerce_to_json({"message" => ex.message}))
        end

        context.command "updater.check" do
          info = u.check_for_updates
          if info
            @update_info = info
            {"version" => info.version, "release_notes" => info.release_notes, "size" => info.size, "channel" => info.channel}
          end
        end

        context.command "updater.download" do
          info = @update_info
          unless info
            raise Core::Error.new("No update available to download", code: "NO_UPDATE")
          end
          path = u.download_update(info)
          {"path" => path.to_s}
        end

        context.command "updater.install" do
          info = @update_info
          path = @package_path
          unless info && path
            raise Core::Error.new("No update downloaded to install", code: "NO_PACKAGE")
          end
          script_path = u.install_update(info, path)
          {"swap_script" => script_path.to_s}
        end

        context.command "updater.status" do
          {
            "current_version" => u.current_version.to_s,
            "phase"           => u.phase.to_s,
            "channel"         => u.channel.to_s,
          }
        end

        context.command "updater.rollback", String? do |version_param|
          script_path = u.rollback(version_param)
          {"swap_script" => script_path.to_s}
        end
      end
    end
  end
end
