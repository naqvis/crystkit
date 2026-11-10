require "json"
require "native_desktop"
require "../security/capability"

module CrystKit::Features
  struct BiometricResult
    include JSON::Serializable
    getter? success : Bool
    getter error : String?

    def initialize(@success : Bool, @error = nil)
    end
  end

  struct BiometricInfo
    include JSON::Serializable
    getter? available : Bool
    getter modality : String?
    getter? reason_supported : Bool

    def initialize(@available : Bool, @modality : String?, @reason_supported : Bool)
    end
  end

  # Capability-gated access to operating-system biometric authentication.
  class BiometricAuth
    CAPABILITY = "biometric:authenticate"

    # :nodoc:
    abstract class Provider
      abstract def info : ::NativeDesktop::BiometricInfo
      abstract def authenticate(reason : String, window : ::NativeDesktop::Window?) : ::NativeDesktop::BiometricResult
    end

    # :nodoc:
    class NativeProvider < Provider
      def info : ::NativeDesktop::BiometricInfo
        ::NativeDesktop.biometric.info
      end

      def authenticate(reason : String, window : ::NativeDesktop::Window?) : ::NativeDesktop::BiometricResult
        ::NativeDesktop.biometric.authenticate(reason, window)
      end
    end

    def initialize(@provider : Provider = NativeProvider.new,
                   @capabilities : Security::CapabilitySystem? = nil)
    end

    def available? : Bool
      @provider.info.available?
    end

    def modality : Symbol?
      modality = @provider.info.modality
      return nil unless modality
      case modality
      in .fingerprint? then :fingerprint
      in .face?        then :face
      in .unknown?     then :unknown
      end
    end

    def biometry_type : Symbol?
      modality
    end

    def info : BiometricInfo
      native = @provider.info
      BiometricInfo.new(native.available?, native.modality.try(&.to_s.underscore), native.reason_supported?)
    end

    def authenticate(reason : String, window : ::NativeDesktop::Window? = nil) : BiometricResult
      @capabilities.try(&.require!(CAPABILITY, context: "biometric_auth"))
      result = @provider.authenticate(reason, window)
      BiometricResult.new(result.success?, result.error)
    end
  end
end
