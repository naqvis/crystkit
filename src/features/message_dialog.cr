require "json"
require "log"
require "../core/errors"
require "./dialog"

module CrystKit
  module Features
    # Severity class of a `MessageDialog#message` alert box.
    enum MessageKind
      # Informational alert (default).
      Info
      # Warning alert.
      Warning
      # Error alert.
      Error
    end

    # Options for `MessageDialog#message`.
    struct MessageOptions
      # Window/dialog title bar text.
      property title : String
      # Body text shown in the alert.
      property message : String
      # Icon and severity class of the alert.
      property kind : MessageKind

      # Creates message-box options with the given *title*, *message*,
      # and severity *kind* (default `Info`).
      def initialize(@title = "Message", @message = "", @kind = MessageKind::Info)
      end
    end

    # Options for `MessageDialog#confirm`.
    struct ConfirmOptions
      # Dialog title bar text.
      property title : String
      # Confirmation prompt body text.
      property message : String

      # Creates confirmation options with the given *title* and *message*.
      def initialize(@title = "Confirm", @message = "")
      end
    end

    # Native message-box and confirmation dialog integration.
    #
    # `MessageDialog` wraps the platform's modal alert boxes. Unlike
    # `FileDialog`, it does not require any capability — message boxes
    # are passive UI and do not grant access to resources.
    #
    # ```
    # dialog = MessageDialog.new
    # if dialog.confirm(ConfirmOptions.new(title: "Quit", message: "Really?"))
    #   app.shutdown
    # end
    # ```
    class MessageDialog
      # Creates a message dialog controller. No security context is required
      # because message boxes do not touch protected resources.
      def initialize(
        @provider : DialogProvider = NativeDialogProvider.new,
      )
      end

      # Show a modal message box.
      #
      # Returns `true` when the user acknowledges the box (e.g., clicks
      # OK). The *kind* controls the platform-specific icon and severity.
      def message(options : MessageOptions) : Bool
        @provider.message(options.title, options.message, options.kind.value)
      end

      # Show a modal confirmation dialog with OK / Cancel buttons.
      #
      # Returns `true` when the user confirms (OK), `false` otherwise.
      def confirm(options : ConfirmOptions) : Bool
        @provider.confirm(options.title, options.message)
      end
    end
  end
end
