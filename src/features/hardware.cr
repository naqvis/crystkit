require "json"
require "log"
require "native_desktop"
require "../core/errors"
require "../security/capability"

module CrystKit
  # The public feature surface of CrystKit.
  #
  # `Features` hosts the high-level capability objects exposed to application
  # code, each enforcing capability and scope checks across platforms
  # enforcement so callers get a uniform, sandboxed API across macOS, Linux
  # and Windows.
  module Features
    # Identifies a hardware bus/API family that CrystKit knows how to enumerate.
    enum HardwareAPIType
      # Bluetooth Classic / BLE peripherals.
      Bluetooth
      # USB devices addressed by vendor/product id.
      USB
      # Serial ports (e.g. `/dev/tty*`, `COM*`).
      Serial
      # Generic Human Interface Devices (keyboards, mice, gamepads).
      HID
      # Near-field-communication readers and tags.
      NFC
    end

    # An immutable description of a single enumerated hardware device.
    #
    # `JSON::Serializable`, so it can flow across the IPC boundary to the
    # frontend. *id* uniquely identifies the device within its `api_type`.
    # *vendor_id* and *product_id* are only populated for bus types that
    # expose them (USB, HID, Bluetooth). *connected* is mutable so a
    # previously-registered device can be marked offline without dropping its
    # metadata.
    class HardwareDeviceInfo
      include JSON::Serializable

      getter id : String
      getter name : String
      getter api_type : HardwareAPIType
      getter vendor_id : UInt16?
      getter product_id : UInt16?
      property? connected : Bool

      # Creates a device descriptor.
      #
      # *id* must be unique within *api_type*. Pass *vendor_id* / *product_id*
      # for bus types that expose them; they are `nil` for `Serial` and `NFC`
      # devices. *connected* defaults to `true`.
      def initialize(@id : String, @name : String, @api_type : HardwareAPIType,
                     @vendor_id = nil, @product_id = nil,
                     @connected = true)
      end
    end

    # High-level hardware device enumeration and lifecycle API.
    #
    # Maintains a thread-safe registry of `HardwareDeviceInfo` records and
    # brokers live system enumeration. Two sources of devices are reconciled:
    #
    # 1. *Registered* devices — pushed by application code via
    #    `#register_device`. `#list_devices` / `#all_devices` read from this
    #    registry.
    # 2. *Enumerated* devices — queried directly from the OS on each call to
    #    `#enumerate`.
    #
    # Every read access (except the trivial `#available?`) is gated by the
    # `hardware:list` capability; mutating the device table additionally
    # requires `hardware:manage`. Handler invocation failures are swallowed
    # and logged so a misbehaving listener cannot break device dispatch.
    #
    # ```
    # api = CrystKit::Features::HardwareAPI.new(caps)
    # api.on_device_connected { |d| Log.info { "Connected: #{d.name}" } }
    # api.enumerate(HardwareAPIType::USB).each { |d| api.register_device(d) }
    # ```
    class HardwareAPI
      Log = ::Log.for(self)

      # :nodoc:
      abstract class Provider
        abstract def available?(type : HardwareAPIType) : Bool
        abstract def enumerate(type : HardwareAPIType) : Array(HardwareDeviceInfo)

        def start_monitor(
          types : Array(HardwareAPIType),
          interval : Time::Span,
          handler : Proc(String, HardwareDeviceInfo, Nil),
        ) : Nil
        end

        def stop_monitor : Nil
        end
      end

      # :nodoc:
      class NativeProvider < Provider
        @monitor = ::NativeDesktop::HardwareMonitor.new

        def available?(type : HardwareAPIType) : Bool
          ::NativeDesktop.hardware.available?(native_kind(type))
        end

        def enumerate(type : HardwareAPIType) : Array(HardwareDeviceInfo)
          ::NativeDesktop.hardware.enumerate(native_kind(type)).map do |device|
            HardwareDeviceInfo.new(device.id, device.name, type, device.vendor_id, device.product_id)
          end
        end

        def start_monitor(
          types : Array(HardwareAPIType),
          interval : Time::Span,
          handler : Proc(String, HardwareDeviceInfo, Nil),
        ) : Nil
          @monitor.start(types.map { |type| native_kind(type) }, interval) do |event|
            device = event.device
            handler.call(
              event.type.value,
              HardwareDeviceInfo.new(
                device.id,
                device.name,
                api_type(device.kind),
                device.vendor_id,
                device.product_id,
                event.type.value == "connected",
              )
            )
          end
        end

        def stop_monitor : Nil
          @monitor.stop
        end

        private def native_kind(type : HardwareAPIType) : ::NativeDesktop::HardwareKind
          case type
          in .bluetooth? then ::NativeDesktop::HardwareKind::Bluetooth
          in .usb?       then ::NativeDesktop::HardwareKind::USB
          in .serial?    then ::NativeDesktop::HardwareKind::Serial
          in .hid?       then ::NativeDesktop::HardwareKind::HID
          in .nfc?       then ::NativeDesktop::HardwareKind::NFC
          end
        end

        private def api_type(kind : ::NativeDesktop::HardwareKind) : HardwareAPIType
          case kind
          in .bluetooth? then HardwareAPIType::Bluetooth
          in .usb?       then HardwareAPIType::USB
          in .serial?    then HardwareAPIType::Serial
          in .hid?       then HardwareAPIType::HID
          in .nfc?       then HardwareAPIType::NFC
          end
        end
      end

      @devices : Hash(String, HardwareDeviceInfo)
      @connect_handlers : Array(Proc(HardwareDeviceInfo, Nil))
      @disconnect_handlers : Array(Proc(String, Nil))
      @mutex : Mutex

      # Creates a new hardware API optionally bound to a capability system.
      #
      # *capabilities* is consulted on every read/write to enforce the
      # `hardware:list` and `hardware:manage` permissions; pass `nil` for an
      # unrestricted instance.
      def initialize(
        @capabilities : Security::CapabilitySystem? = nil,
        @provider : Provider = NativeProvider.new,
      )
        @devices = Hash(String, HardwareDeviceInfo).new
        @connect_handlers = [] of Proc(HardwareDeviceInfo, Nil)
        @disconnect_handlers = [] of Proc(String, Nil)
        @mutex = Mutex.new
      end

      # Returns `true` if the current platform can enumerate devices of *type*.
      #
      # Performs no capability check and never raises, making it suitable for
      # UI gating (e.g. enabling/disabling a "Scan for USB devices" button).
      def available?(type : HardwareAPIType) : Bool
        @provider.available?(type)
      end

      # Returns the currently registered, connected devices of *type*.
      #
      # Does *not* trigger an OS scan. Requires the `hardware:list` capability;
      # raises `Core::SecurityError` (code `CAPABILITY_DENIED`) on denial.
      def list_devices(type : HardwareAPIType) : Array(HardwareDeviceInfo)
        @capabilities.try(&.require!("hardware:list"))
        @mutex.synchronize do
          @devices.values.select { |device| device.api_type == type && device.connected? }
        end
      end

      # Perform a live, one-shot scan of the system for devices of the given
      # type.
      #
      # Queries the OS directly each time it is called. Returns an empty array
      # on unsupported platforms.
      def enumerate(type : HardwareAPIType) : Array(HardwareDeviceInfo)
        @capabilities.try(&.require!("hardware:list"))
        @provider.enumerate(type)
      rescue ex
        Log.warn { "HardwareAPI: enumerate failed: #{ex.message}" }
        [] of HardwareDeviceInfo
      end

      # Returns every connected device currently in the registry, regardless
      # of `HardwareAPIType`.
      #
      # Requires the `hardware:list` capability and raises `Core::SecurityError`
      # on denial.
      def all_devices : Array(HardwareDeviceInfo)
        @capabilities.try(&.require!("hardware:list"))
        @mutex.synchronize do
          @devices.values.select(&.connected?)
        end
      end

      # Inserts or replaces *device* in the registry and fires
      # `on_device_connected` handlers.
      #
      # Replacing an existing id with a new descriptor is treated as a fresh
      # connect event. Handler exceptions are swallowed and logged so failures
      # do not roll back the registration. No capability check is required.
      def register_device(device : HardwareDeviceInfo) : Nil
        handlers = @mutex.synchronize do
          @devices[device.id] = device
          @connect_handlers.dup
        end
        notify_connect_handlers(handlers, device)
      end

      # Marks the device identified by *device_id* as disconnected and fires
      # `on_device_disconnected` handlers with the id.
      #
      # The record is *not* removed from the table — its `connected` flag is
      # flipped to `false` so its metadata remains available to disconnect
      # handlers. No-op (and no handler invocation) when *device_id* is
      # unknown.
      def unregister_device(device_id : String) : Nil
        handlers = @mutex.synchronize do
          if device = @devices[device_id]?
            device.connected = false
            @disconnect_handlers.dup
          end
        end
        notify_disconnect_handlers(handlers, device_id) if handlers
      end

      # Permanently removes a device descriptor from the registry.
      #
      # Unlike `#unregister_device` (which only flips the connected flag),
      # this drops the entry entirely. Requires the `hardware:manage`
      # capability; raises `Core::SecurityError` (code `CAPABILITY_DENIED`)
      # on denial.
      def forget_device(device_id : String) : Nil
        @capabilities.try(&.require!("hardware:manage"))
        @mutex.synchronize do
          @devices.delete(device_id)
        end
      end

      # Registers a callback invoked synchronously whenever a device is
      # registered (or re-registered) via `#register_device`.
      #
      # The handler receives the freshly-registered `HardwareDeviceInfo`.
      # Exceptions raised inside the handler are caught and logged at `WARN`
      # level, so one listener cannot break dispatch to the others. Handlers
      # are invoked in registration order.
      def on_device_connected(&block : HardwareDeviceInfo -> Nil) : Nil
        @mutex.synchronize { @connect_handlers << block }
      end

      # Registers a callback invoked synchronously whenever a device is
      # marked disconnected via `#unregister_device`.
      #
      # The handler receives the device's `id` string rather than the full
      # descriptor. Handler exceptions are caught and logged so dispatch
      # continues to subsequent listeners.
      def on_device_disconnected(&block : String -> Nil) : Nil
        @mutex.synchronize { @disconnect_handlers << block }
      end

      # Starts operating-system device monitoring. Events update the existing
      # registry and flow through the normal connected/disconnected handlers.
      def start_monitoring(
        types : Array(HardwareAPIType) = HardwareAPIType.values,
        interval : Time::Span = 2.seconds,
      ) : Nil
        @capabilities.try(&.require!("hardware:list"))
        raise ArgumentError.new("hardware monitor requires at least one device type") if types.empty?
        handler = ->(event_type : String, device : HardwareDeviceInfo) do
          if event_type == "connected"
            register_device(device)
          else
            @mutex.synchronize { @devices[device.id] ||= device }
            unregister_device(device.id)
          end
        end
        @provider.start_monitor(types, interval, handler)
      end

      def stop_monitoring : Nil
        @provider.stop_monitor
      end

      # :nodoc:
      private def notify_connect_handlers(handlers : Array(Proc(HardwareDeviceInfo, Nil)), device : HardwareDeviceInfo) : Nil
        handlers.each do |handler|
          handler.call(device)
        rescue ex
          Log.warn { "Device connect handler error: #{ex.message}" }
        end
      end

      # :nodoc:
      private def notify_disconnect_handlers(handlers : Array(Proc(String, Nil)), device_id : String) : Nil
        handlers.each do |handler|
          handler.call(device_id)
        rescue ex
          Log.warn { "Device disconnect handler error: #{ex.message}" }
        end
      end
    end
  end
end
