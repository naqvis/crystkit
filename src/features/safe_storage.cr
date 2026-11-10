require "safe_storage"

module CrystKit::Features
  # CrystKit compatibility adapter around the standalone safe_storage shard.
  # Application and plugin security remain in CrystKit; native credential
  # storage and its error model are owned by the shard.
  class SafeStorage
    def initialize
      @vaults = {} of String => ::SafeStorage::Vault
      @lock = Mutex.new
    end

    def set(key : String, value : String, service : String = "CrystKit") : Nil
      vault(service).store(key, value)
    end

    def get(key : String, service : String = "CrystKit") : String?
      vault(service).fetch?(key)
    end

    def delete(key : String, service : String = "CrystKit") : Nil
      vault(service).delete(key)
    end

    def list(service : String = "CrystKit") : Array(String)
      vault(service).keys
    end

    private def vault(service : String) : ::SafeStorage::Vault
      @lock.synchronize do
        @vaults[service] ||= ::SafeStorage.open(service)
      end
    end
  end
end
