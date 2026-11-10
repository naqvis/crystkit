require "./interface"
require "./backends/window_backend"
require "./backends/window_integration_backend"
require "./backends/drag_drop_backend"
require "./backends/printing_backend"
require "./backends/custom_protocol_backend"

module CrystKit::Platform
  # Composition of native service backends.
  #
  # The facade through which the CrystKit runtime reaches every platform
  # capability. A custom backend can be injected for any capability by
  # passing it to the constructor (primarily useful for tests).
  #
  # ```
  # services = Platform::Services.new
  # ```
  class Services
    # The window creation and content-loading backend.
    getter window : WindowBackend { CurrentWindowBackend.new }

    # The window-integration backend for permissions and DevTools wiring.
    getter window_integration : WindowIntegrationBackend { CurrentWindowIntegrationBackend.new }

    # The drag-drop backend for receiving native drop events on windows.
    getter drag_drop : DragDropBackend { CurrentDragDropBackend.new }

    # The printing and PDF-export backend.
    getter printing : PrintingBackend { CurrentPrintingBackend.new }

    # The custom protocol handler backend for WebView URL schemes.
    getter custom_protocol : CustomProtocolBackend { CurrentCustomProtocolBackend.new }

    # Creates a service composition, optionally overriding individual
    # backends.
    #
    # Every parameter defaults to `nil`, in which case the platform
    # default backend is used. Pass a concrete backend instance to
    # substitute it.
    def initialize(
      @window = nil,
      @window_integration = nil,
      @drag_drop = nil,
      @printing = nil,
      @custom_protocol = nil,
    )
    end
  end
end
