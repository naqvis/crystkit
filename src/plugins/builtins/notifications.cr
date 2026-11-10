require "../base"
require "../../features/notifications"

module CrystKit
  module Plugins
    # Plugin exposing native desktop notifications to the frontend.
    #
    # The plugin requests OS permission once on startup so notifications are
    # ready to display without an explicit frontend round-trip.
    #
    # Registers IPC commands:
    #   notification:request_permission, notification:show
    #
    # Required capability: `notification:show`
    class Notifications < Plugin::Base
      Log = ::Log.for(self)
      getter! notifications : Features::Notifications

      def identifier : String
        "notifications"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(notification.request_permission notification.show notification.close), "notification:show")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(notification:show),
          commands: %w(notification.request_permission notification.show notification.close),
          events: %w(notification.event),
          ipc: ipc,
        )
      end

      # `notification.show` takes *title*, *body*, and *urgency* (a string
      # parsed into `Features::Urgency`) and returns the id of the displayed
      # `Features::NotificationHandle` so the frontend can later dismiss it.
      #
      # Raises `Core::Error` (code `PERMISSION_NOT_GRANTED`) if `show`
      # is invoked without OS permission.
      def initialize_plugin(context : Plugin::Context) : Nil
        @notifications = n = Features::Notifications.new(
          context.capabilities,
          app_name: context.app.config.name,
        )
        n.on_event do |event|
          context.emit("notification.event", context.app.coerce_to_json({
            "id"        => event.id,
            "type"      => event.type,
            "action_id" => event.action_id,
            "error"     => event.error,
          }))
        end

        # OS permission is requested lazily on first use (via
        # `notification.request_permission` below) because the native desktop
        # runtime is not yet attached at plugin-registration time.

        context.command "notification.request_permission" do
          n.request_permission
        end

        context.command "notification.show", String, String, String do |title, body, urgency|
          notif = Features::Notification.new(title, body)
          notif.urgency = Features::Urgency.parse(urgency)
          n.show(notif).id
        end

        context.command "notification.close", String do |handle_id|
          n.close(Features::NotificationHandle.new(handle_id))
        end
      end

      def cleanup_plugin : Nil
        @notifications.try(&.cleanup)
      end
    end
  end
end
