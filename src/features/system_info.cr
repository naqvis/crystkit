require "system_info"

module CrystKit::Features
  alias CPUInfo = ::SystemInfo::CPU
  alias MemoryInfo = ::SystemInfo::Memory
  alias DiskInfo = ::SystemInfo::Filesystem
  alias VolumeInfo = ::SystemInfo::Volume
  alias NetworkInterface = ::SystemInfo::NetworkInterface
  alias Display = ::SystemInfo::Display
  alias Architecture = ::SystemInfo::Architecture
  alias OSInfo = ::SystemInfo::OS
  alias LocaleInfo = ::SystemInfo::Locale
  alias AppDataDirectories = ::SystemInfo::Directories

  # Application build metadata supplied through the process environment.
  record AppInfo, version : String, build : String, build_time : String? = nil do
    def to_s(io : IO) : Nil
      io << version << " (" << build << ')'
    end
  end

  # CrystKit feature facade for typed host information.
  class SystemInfo
    # :nodoc:
    abstract class Provider
      abstract def os : OSInfo
      abstract def architecture : Architecture
      abstract def locale : LocaleInfo
      abstract def hostname : String
      abstract def cpu : CPUInfo
      abstract def memory : MemoryInfo
      abstract def filesystem(path : String) : DiskInfo
      abstract def removable?(path : String) : Bool
      abstract def volumes : Array(VolumeInfo)
      abstract def network_interfaces : Array(NetworkInterface)
      abstract def displays : Array(Display)
      abstract def home_directory : String
      abstract def directories : AppDataDirectories
    end

    # :nodoc:
    class NativeProvider < Provider
      def os : OSInfo
        ::SystemInfo.os
      end

      def architecture : Architecture
        ::SystemInfo.architecture
      end

      def locale : LocaleInfo
        ::SystemInfo.locale
      end

      def hostname : String
        ::SystemInfo.hostname
      end

      def cpu : CPUInfo
        ::SystemInfo.cpu
      end

      def memory : MemoryInfo
        ::SystemInfo.memory
      end

      def filesystem(path : String) : DiskInfo
        ::SystemInfo.filesystem(path)
      end

      def removable?(path : String) : Bool
        ::SystemInfo.removable_media?(path)
      end

      def volumes : Array(VolumeInfo)
        ::SystemInfo.volumes
      end

      def network_interfaces : Array(NetworkInterface)
        ::SystemInfo.network_interfaces
      end

      def displays : Array(Display)
        ::SystemInfo.displays
      end

      def home_directory : String
        ::SystemInfo.home_directory
      end

      def directories : AppDataDirectories
        ::SystemInfo.directories
      end
    end

    def initialize(@provider : Provider = NativeProvider.new)
    end

    def os_info : OSInfo
      @provider.os
    end

    def architecture : Architecture
      @provider.architecture
    end

    def locale_info : LocaleInfo
      @provider.locale
    end

    def hostname : String
      @provider.hostname
    end

    def cpu_info : CPUInfo
      @provider.cpu
    end

    def memory_info : MemoryInfo
      @provider.memory
    end

    def disk_info(path : String = "/") : DiskInfo
      @provider.filesystem(path)
    end

    def ejectable?(path : String) : Bool
      @provider.removable?(path)
    end

    def list_mounts : Array(VolumeInfo)
      @provider.volumes
    end

    def network_interfaces : Array(NetworkInterface)
      @provider.network_interfaces
    end

    def display_info : Array(Display)
      @provider.displays
    end

    def app_info : AppInfo
      AppInfo.new(
        ENV["APP_VERSION"]? || "0.0.0",
        ENV["APP_BUILD"]? || "development",
        ENV["APP_BUILD_TIME"]?,
      )
    end

    def home_directory : String
      @provider.home_directory
    end

    def app_data_directories : AppDataDirectories
      @provider.directories
    end
  end
end
