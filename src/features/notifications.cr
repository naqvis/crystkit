require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../security/capability"
require "./asset_resolution"
require "./asset_source"
require "./asset_fetcher"
require "../platform/icon_source"

module CrystKit::Features
  # Urgency level for a desktop notification.
  #
  # `Low` is non-intrusive, `Normal` is the desktop default, and `Critical`
  # may bypass quiet hours on supported systems.
  enum Urgency
    Low
    Normal
    Critical
  end

  # A button displayed inside a notification.
  #
  # Each action is identified by an application-defined *id* and rendered
  # with a user-visible *label*.
  struct NotificationAction
    getter id : String
    getter label : String

    def initialize(@id : String, @label : String)
    end
  end

  # Opaque reference to a notification that has been displayed.
  #
  # Pass this handle back to `Notifications#close` to dismiss the
  # notification before its timeout expires.
  struct NotificationHandle
    getter id : String

    def initialize(@id : String)
    end
  end

  record NotificationLifecycleEvent,
    id : String,
    type : String,
    action_id : String? = nil,
    error : String? = nil

  # Description of a notification to be displayed to the user.
  #
  # Configure the visible fields (title, body, icon, urgency, timeout) and
  # any action buttons, then register callbacks for click and action events
  # before passing the instance to `Notifications#show`.
  class Notification
    property title : String
    property body : String
    property icon : Path | URI | String | Nil
    property actions : Array(NotificationAction)
    property urgency : Urgency
    property timeout : Time::Span?
    @click_handler : Proc(Nil)?
    @action_handler : Proc(String, Nil)?

    def initialize(@title : String, @body = "")
      @actions = [] of NotificationAction
      @urgency = Urgency::Normal
    end

    # Register a block invoked when the user clicks the notification body.
    def on_click(&block : ->)
      @click_handler = block
    end

    # Register a block invoked when the user activates an action button.
    #
    # The block receives the *id* of the `NotificationAction` that was activated.
    def on_action(&block : String ->)
      @action_handler = block
    end

    # :nodoc:
    def trigger_click
      @click_handler.try(&.call)
    end

    # :nodoc:
    def trigger_action(action_id : String)
      @action_handler.try(&.call(action_id))
    end
  end

  # Displays native desktop notifications, gated by the `"notification:show"`
  # capability.
  class Notifications
    Log = ::Log.for(self)

    # Internal seam used by CrystKit specs. Application code does not provide
    # notification platform implementations.
    # :nodoc:
    abstract class Provider
      abstract def request_permission(app_name : String) : Bool
      abstract def show(app_name : String, id : String, title : String, body : String,
                        icon : Platform::IconSource?, urgency : Int32, timeout_ms : Int32,
                        actions : Array({String, String})) : Nil
      abstract def close(id : String) : Nil

      def subscribe(&handler : NotificationLifecycleEvent -> Nil) : Proc(Nil)?
        nil
      end
    end

    # :nodoc:
    class NativeProvider < Provider
      def request_permission(app_name : String) : Bool
        ::NativeDesktop.permissions
          .request(::NativeDesktop::PermissionIds::Notifications)
          .state
          .granted?
      end

      def show(app_name : String, id : String, title : String, body : String,
               icon : Platform::IconSource?, urgency : Int32, timeout_ms : Int32,
               actions : Array({String, String})) : Nil
        native_icon = if icon
                        if bytes = icon.bytes
                          ::NativeDesktop::NotificationIcon.bytes(bytes, icon.key)
                        elsif name = icon.name
                          ::NativeDesktop::NotificationIcon.name(name)
                        end
                      end
        native_actions = actions.map { |action_id, label| ::NativeDesktop::NotificationAction.new(action_id, label) }
        request = ::NativeDesktop::NotificationRequest.new(
          id,
          title,
          body,
          native_icon,
          ::NativeDesktop::NotificationUrgency.from_value(urgency),
          timeout_ms < 0 ? nil : timeout_ms.milliseconds,
          native_actions
        )
        ::NativeDesktop.notifications.show(app_name, request)
      end

      def close(id : String) : Nil
        ::NativeDesktop.notifications.close(id)
      end

      def subscribe(&handler : NotificationLifecycleEvent -> Nil) : Proc(Nil)?
        registration = ::NativeDesktop.notifications.on_event do |event|
          handler.call(NotificationLifecycleEvent.new(
            event.id,
            event.type.value,
            event.action_id,
            event.error.try(&.message),
          ))
        end
        -> { registration.close }
      end
    end

    @capabilities : Security::CapabilitySystem
    @permission_granted : Bool
    @active : Hash(String, Notification)
    @handle_counter : Int32
    @asset_source : AssetSource?
    @asset_fetcher : AssetFetcher?
    @event_handlers = [] of Proc(NotificationLifecycleEvent, Nil)
    @unsubscribe : Proc(Nil)?

    def initialize(
      @capabilities : Security::CapabilitySystem,
      @provider : Provider = NativeProvider.new,
      @app_name : String = CrystKit::AppConfig::DEFAULT_NAME,
      asset_source : AssetSource? = nil,
      asset_fetcher : AssetFetcher? = nil,
    )
      @permission_granted = false
      @active = Hash(String, Notification).new
      @handle_counter = 0
      @asset_source = asset_source
      @asset_fetcher = asset_fetcher
      @unsubscribe = @provider.subscribe { |event| handle_platform_event(event) }
    end

    # Request OS-level permission to display notifications.
    #
    # Idempotent for the lifetime of this instance.
    def request_permission : Bool
      @permission_granted = platform_request_permission
      Log.debug { "Notifications: permission granted=#{@permission_granted}" }
      @permission_granted
    end

    # Display *notification* to the user.
    #
    # Requires the `"notification:show"` capability and that
    # `request_permission` has returned `true`; otherwise raises
    # `Core::Error` with code `PERMISSION_NOT_GRANTED`. Returns a
    # `NotificationHandle` that can be used to close the notification.
    #
    # ```
    # notif = Notification.new("Hello", "World")
    # notif.on_click { puts "clicked" }
    # handle = notifications.show(notif)
    # ```
    def show(notification : Notification) : NotificationHandle
      @capabilities.require!("notification:show")

      unless @permission_granted
        Log.warn { "Notifications: cannot show '#{notification.title}' — permission not granted" }
        raise Core::Error.new(
          "Notification permission not granted",
          code: "PERMISSION_NOT_GRANTED"
        )
      end

      Log.debug { "Notifications: showing '#{notification.title}'" }
      @handle_counter += 1
      handle = NotificationHandle.new("notif_#{@handle_counter}")
      @active[handle.id] = notification

      platform_show(handle, notification)
      handle
    end

    # Dismiss the notification identified by *handle*.
    #
    # Safe to call on an already-expired notification.
    def close(handle : NotificationHandle)
      @active.delete(handle.id)
      platform_close(handle)
    end

    # Invoked by the platform layer when the notification body is clicked.
    # :nodoc:
    def handle_click(handle_id : String)
      @active[handle_id]?.try(&.trigger_click)
    end

    # Invoked by the platform layer when an action button is activated.
    # :nodoc:
    def handle_action(handle_id : String, action_id : String)
      @active[handle_id]?.try(&.trigger_action(action_id))
    end

    # Registers a lifecycle listener for activation, action, dismissal, failure,
    # and extension-defined notification events.
    def on_event(&handler : NotificationLifecycleEvent -> Nil) : Nil
      @event_handlers << handler
    end

    # Releases the native lifecycle subscription.
    def cleanup : Nil
      @unsubscribe.try(&.call)
      @unsubscribe = nil
      @event_handlers.clear
      @active.clear
    end

    # :nodoc:
    private def platform_request_permission : Bool
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.request_permission(@app_name)
      }
    end

    # :nodoc:
    private def platform_show(handle : NotificationHandle, notification : Notification)
      actions = notification.actions.map { |action_item| {action_item.id, action_item.label} }
      timeout_ms = notification.timeout.try(&.total_milliseconds.to_i) || -1
      urgency_int = notification.urgency.value

      icon_source = resolve_notification_icon(notification.icon)
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.show(
          @app_name, handle.id, notification.title, notification.body,
          icon_source, urgency_int, timeout_ms,
          actions
        )
      }
    end

    # :nodoc:
    private def resolve_notification_icon(icon : Path | URI | String | Nil) : Platform::IconSource?
      case icon
      when Path
        AssetResolution.resolve(icon, @asset_source)
      when String
        AssetResolution.resolve(icon, @asset_source)
      when URI
        # Async: notification shows with no icon; swap in when bytes land.
        # libnotify sets the icon at creation time, so a late-arriving
        # network icon is logged and dropped on platforms that can't
        # update post-show.
        if fetcher = @asset_fetcher
          fetcher.fetch_async(icon,
            on_ready: ->(_src : Platform::IconSource) { Log.debug { "Notifications: network icon arrived after show" } })
        else
          Log.warn { "Notifications: URI icon '#{icon}' cannot be loaded — no AssetFetcher wired in" }
        end
        nil
      when Nil
        nil
      end
    end

    # :nodoc:
    private def platform_close(handle : NotificationHandle)
      ::CrystKit::Core::MainThread.dispatch_sync {
        @provider.close(handle.id)
      }
    end

    private def handle_platform_event(event : NotificationLifecycleEvent) : Nil
      case event.type
      when "activated"
        handle_click(event.id)
      when "action-selected"
        event.action_id.try { |action_id| handle_action(event.id, action_id) }
      when "dismissed", "failed"
        @active.delete(event.id)
      end
      @event_handlers.each(&.call(event))
    end
  end
end
