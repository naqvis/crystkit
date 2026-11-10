require "../base"
require "../../features/session_lifecycle"

module CrystKit::Plugins
  class SessionLifecycle < Plugin::Base
    getter! session : Features::SessionLifecycle

    def identifier : String
      "session_lifecycle"
    end

    def metadata : Plugin::Metadata
      Plugin::Metadata.new(identifier, events: %w(session.changed))
    end

    def initialize_plugin(context : Plugin::Context) : Nil
      @session = feature = Features::SessionLifecycle.new
      feature.start do |change|
        context.emit("session.changed", context.app.coerce_to_json({
          "type"      => change.type,
          "timestamp" => change.timestamp,
        }))
      end
    end

    def cleanup_plugin : Nil
      @session.try(&.stop)
    end
  end
end
