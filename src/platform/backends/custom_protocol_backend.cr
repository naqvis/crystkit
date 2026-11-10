require "../interface"

{% if flag?(:darwin) %}
  require "../macos/custom_protocol"
{% elsif flag?(:linux) %}
  require "../linux/custom_protocol"
{% elsif flag?(:windows) %}
  require "../windows/custom_protocol"
{% end %}

module CrystKit
  module Platform
    abstract class CustomProtocolBackend
      abstract def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil

      abstract def register(window : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
    end

    class CurrentCustomProtocolBackend < CustomProtocolBackend
      def setup(scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil
        {% if flag?(:darwin) %}
          Current::CustomProtocol.setup(scheme, resolver)
        {% end %}
      end

      def register(window : T, scheme : String, resolver : Proc(String, {Bytes, String}?)) : Nil forall T
        Current::CustomProtocol.register(window, scheme, resolver)
      end
    end
  end
end
