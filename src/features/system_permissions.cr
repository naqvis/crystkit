require "native_desktop"

module CrystKit::Features
  # Operating-system permission state. This is intentionally separate from
  # `Permissions`, which governs permission requests originating in WebView
  # content and is scoped by origin.
  record SystemPermission,
    id : String,
    state : String,
    can_request : Bool,
    settings_available : Bool do
    include JSON::Serializable
  end

  class SystemPermissions
    abstract class Provider
      abstract def status(id : String) : SystemPermission
      abstract def request(id : String) : SystemPermission
      abstract def open_settings(id : String) : Bool
    end

    class NativeProvider < Provider
      def status(id : String) : SystemPermission
        convert(::NativeDesktop.permissions.status(id))
      end

      def request(id : String) : SystemPermission
        convert(::NativeDesktop.permissions.request(id))
      end

      def open_settings(id : String) : Bool
        ::NativeDesktop.permissions.open_settings(id)
      end

      private def convert(info : ::NativeDesktop::PermissionInfo) : SystemPermission
        SystemPermission.new(
          info.permission.value,
          info.state.to_s.underscore.gsub('_', '-'),
          info.can_request,
          info.settings_available,
        )
      end
    end

    def initialize(@provider : Provider = NativeProvider.new)
    end

    def status(id : String) : SystemPermission
      @provider.status(validate(id))
    end

    def request(id : String) : SystemPermission
      @provider.request(validate(id))
    end

    def open_settings(id : String) : Bool
      @provider.open_settings(validate(id))
    end

    private def validate(id : String) : String
      raise ArgumentError.new("permission identifier cannot be empty") if id.strip.empty?
      id
    end
  end
end
