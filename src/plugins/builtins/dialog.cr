require "../base"
require "../../features/dialog"
require "../../features/message_dialog"

module CrystKit
  module Plugins
    # Plugin exposing native file and message dialogs to the frontend.
    #
    # File operations (`dialog.open_file`, `dialog.open_files`,
    # `dialog.save_file`, `dialog.select_folder`) are routed through
    # `Features::FileDialog` and require the `dialog:open` / `dialog:save`
    # capabilities; returned paths are persisted with read/write scopes
    # for subsequent filesystem operations without re-prompting.
    #
    # Message operations (`dialog.message`, `dialog.confirm`) are routed
    # through `Features::MessageDialog` and require no capability — they
    # are passive UI and do not touch protected resources.
    #
    # Required capabilities: `dialog:open`, `dialog:save`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Dialog.new)
    # ```
    class Dialog < Plugin::Base
      # :nodoc:
      def initialize(@provider : Features::DialogProvider = Features::NativeDialogProvider.new)
      end

      # A single file-type filter entry in an `OpenRequest` or `SaveRequest`.
      struct FilterDef
        include JSON::Serializable
        # Human-readable label shown in the dialog's filter dropdown.
        getter name : String
        # File extensions (no leading dot) matched by this filter.
        getter extensions : Array(String)
      end

      # Request payload for `dialog.open_file`, `dialog.open_files`, and
      # `dialog.select_folder`.
      struct OpenRequest
        include JSON::Serializable
        # Optional dialog title; the platform backend supplies a default when
        # `nil`.
        getter title : String?
        # Optional starting directory for the dialog.
        getter default_path : String?
        # Optional file-type filters; omitting them leaves the filter list
        # empty, which on most platforms means "all files".
        getter filters : Array(FilterDef)?
        getter accept_label : String?
        getter show_hidden : Bool = false
        getter can_create_directories : Bool = true
      end

      # Request payload for `dialog.save_file`.
      struct SaveRequest
        include JSON::Serializable
        # Optional dialog title.
        getter title : String?
        # Pre-filled filename in the save dialog.
        getter default_name : String?
        # Optional starting directory for the dialog.
        getter default_path : String?
        # Optional file-type filters.
        getter filters : Array(FilterDef)?
        getter accept_label : String?
        getter default_extension : String?
        getter show_hidden : Bool = false
        getter can_create_directories : Bool = true
        getter confirm_overwrite : Bool = true
      end

      # Request payload for `dialog.message`.
      #
      # *kind* is a case-insensitive string selector (`"info"`, `"warning"`,
      # `"error"`) mapped to `Features::MessageKind`; unknown values fall back
      # to `Info`.
      struct MessageRequest
        include JSON::Serializable
        # Dialog title.
        getter title : String
        # Body text of the message box.
        getter message : String
        # Severity selector; defaults to `"info"`.
        getter kind : String = "info"
      end

      # Request payload for `dialog.confirm`.
      struct ConfirmRequest
        include JSON::Serializable
        # Dialog title.
        getter title : String
        # Body text prompting the user to confirm.
        getter message : String
      end

      # The file-dialog controller. Shortcut for `file_dialog`.
      getter! dialog : Features::FileDialog

      # The file-dialog controller, exposing `open_file`, `open_files`,
      # `save_file`, and `select_folder`.
      getter! file_dialog : Features::FileDialog

      # The message-dialog controller, exposing `message` and `confirm`.
      getter! message_dialog : Features::MessageDialog

      def identifier : String
        "dialog"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(dialog.open_file dialog.open_files dialog.select_folder dialog.message dialog.confirm), "dialog:open")
          .require("dialog.save_file", "dialog:save")

        Plugin::Metadata.new(
          identifier,
          capabilities: ["dialog:open", "dialog:save"],
          commands: %w(
            dialog.open_file dialog.open_files dialog.save_file
            dialog.select_folder dialog.message dialog.confirm
          ),
          ipc: ipc,
        )
      end

      # `dialog.open_file` returns the chosen path as a string or `nil` when
      # the user cancels. `dialog.open_files` always returns an array of
      # strings (possibly empty). `dialog.save_file` returns the target path
      # as a string or `nil`. `dialog.select_folder` returns the selected
      # folder or `nil`. `dialog.confirm` returns the boolean result of the
      # confirm dialog.
      #
      # Long *default_path*/*default_name* values are rejected by
      # `Features::FileDialog` with `Core::Error` (`PATH_TOO_LONG` /
      # `NAME_TOO_LONG`), and `dialog.open_files` raises when more than
      # `Features::FileDialog::MAX_MULTIPLE_FILES` are selected.
      def initialize_plugin(context : Plugin::Context) : Nil
        @dialog = @file_dialog = fd = Features::FileDialog.new(context.security, @provider)
        @message_dialog = md = Features::MessageDialog.new(@provider)

        context.command_context("dialog.open_file") do |ipc_context, params|
          request = IPC::Router.decode(params, OpenRequest)
          filters = request.filters.try { |f| f.map { |fd| Features::FileFilter.new(fd.name, fd.extensions) } } || [] of Features::FileFilter
          opts = Features::OpenFileOptions.new(
            title: request.title,
            default_path: request.default_path.try { |path| Path[path] },
            filters: filters,
            multiple: false,
            owner: ipc_context.window.try(&.window),
            accept_label: request.accept_label,
            show_hidden: request.show_hidden,
          )
          fd.open_file(opts).try(&.to_s)
        end

        context.command_context("dialog.open_files") do |ipc_context, params|
          request = IPC::Router.decode(params, OpenRequest)
          filters = request.filters.try { |f| f.map { |fd| Features::FileFilter.new(fd.name, fd.extensions) } } || [] of Features::FileFilter
          opts = Features::OpenFileOptions.new(
            title: request.title,
            default_path: request.default_path.try { |path| Path[path] },
            filters: filters,
            multiple: true,
            owner: ipc_context.window.try(&.window),
            accept_label: request.accept_label,
            show_hidden: request.show_hidden,
          )
          fd.open_files(opts).map(&.to_s)
        end

        context.command_context("dialog.save_file") do |ipc_context, params|
          request = IPC::Router.decode(params, SaveRequest)
          filters = request.filters.try { |f| f.map { |fd| Features::FileFilter.new(fd.name, fd.extensions) } } || [] of Features::FileFilter
          opts = Features::SaveFileOptions.new(
            title: request.title,
            default_path: request.default_path.try { |path| Path[path] },
            default_name: request.default_name,
            filters: filters,
            owner: ipc_context.window.try(&.window),
            accept_label: request.accept_label,
            default_extension: request.default_extension,
            show_hidden: request.show_hidden,
            can_create_directories: request.can_create_directories,
            confirm_overwrite: request.confirm_overwrite,
          )
          fd.save_file(opts).try(&.to_s)
        end

        context.command_context("dialog.select_folder") do |ipc_context, params|
          request = IPC::Router.decode(params, OpenRequest)
          opts = Features::FolderOptions.new(
            title: request.title,
            default_path: request.default_path.try { |path| Path[path] },
            owner: ipc_context.window.try(&.window),
            accept_label: request.accept_label,
            show_hidden: request.show_hidden,
            can_create_directories: request.can_create_directories,
          )
          fd.select_folder(opts).try(&.to_s)
        end

        context.command("dialog.message", MessageRequest) do |request|
          kind_enum = case request.kind.downcase
                      when "warning" then Features::MessageKind::Warning
                      when "error"   then Features::MessageKind::Error
                      else                Features::MessageKind::Info
                      end
          md.message(Features::MessageOptions.new(title: request.title, message: request.message, kind: kind_enum))
        end

        context.command("dialog.confirm", ConfirmRequest) do |request|
          md.confirm(Features::ConfirmOptions.new(title: request.title, message: request.message))
        end
      end
    end
  end
end
