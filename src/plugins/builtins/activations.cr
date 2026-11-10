require "../base"
require "../../features/activations"

module CrystKit::Plugins
  class Activations < Plugin::Base
    getter! activations : Features::Activations
    @context : Plugin::Context?
    @subscription : Features::Activations::Subscription?

    def identifier : String
      "activations"
    end

    def metadata : Plugin::Metadata
      Plugin::Metadata.new(identifier, events: %w(activation.received))
    end

    def initialize_plugin(context : Plugin::Context) : Nil
      @context = context
      @activations = feature = context.app.runtime.activations
      @subscription = feature.on_event do |activation|
        context.emit("activation.received", context.app.coerce_to_json({
          "type"      => activation.type,
          "values"    => activation.values,
          "timestamp" => activation.timestamp,
        }))
      end
    end

    def cleanup_plugin : Nil
      @subscription.try(&.close)
      @subscription = nil
      @context = nil
    end
  end
end
