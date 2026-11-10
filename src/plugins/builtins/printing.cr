require "../base"
require "../../features/printing"

module CrystKit
  module Plugins
    # Builtin plugin that exposes printing and PDF export to the frontend.
    #
    # Splits commands across three capabilities: direct printing and the
    # print dialog require `printing:print`, PDF export requires
    # `printing:pdf`, and enumerating installed printers requires
    # `printing:info`.
    #
    # Registers IPC commands:
    #   printing.print, printing.print_to_pdf,
    #   printing.list_printers, printing.show_dialog
    #
    # Required capabilities: `printing:print`, `printing:pdf`, `printing:info`
    class Printing < Plugin::Base
      # The `Features::Printer`, lazily initialized during `#initialize_plugin`.
      #
      # Raises `NilAssertionError` if accessed before the plugin has been
      # initialized.
      getter! printer : Features::Printer

      # Returns the unique plugin identifier `"printing"`.
      def identifier : String
        "printing"
      end

      # Returns the metadata contract splitting printing commands across the
      # `printing:print`, `printing:pdf`, and `printing:info` capabilities.
      #
      # `printing.print` and `printing.show_dialog` require `printing:print`;
      # `printing.print_to_pdf` requires `printing:pdf`; `printing.list_printers`
      # requires `printing:info`.
      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(printing.print printing.show_dialog), "printing:print")
          .require("printing.print_to_pdf", "printing:pdf")
          .require("printing.list_printers", "printing:info")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(printing:print printing:pdf printing:info),
          commands: %w(printing.print printing.print_to_pdf printing.list_printers printing.show_dialog),
          ipc: ipc,
        )
      end

      # Registers the four IPC commands.
      #
      # The print, PDF, and dialog commands return
      # `{"success" => false, "error" => ...}` when no window or native
      # handle is available. *opts* is a JSON object decoded into
      # `Features::PrintOptions`; unrecognized keys fall back to the feature's
      # defaults (1 copy, portrait, color, A4, scale 1.0, 20pt margins).
      # `printing.list_printers` returns `{"printers" => [...]}`.
      def initialize_plugin(context : Plugin::Context) : Nil
        p = Features::Printer.new(context.capabilities, context.app.runtime.platform.printing)
        @printer = p

        context.command "printing.print", JSON::Any do |opts|
          wv = context.app.primary_window
          next {"success" => false, "error" => "No window"} unless wv
          native = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          next {"success" => false, "error" => "No native handle"} unless native
          options = parse_print_options(opts)
          {"success" => p.print(native, options)}
        end

        context.command "printing.print_to_pdf", String, JSON::Any do |path, opts|
          wv = context.app.primary_window
          next {"success" => false, "error" => "No window"} unless wv
          native = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          next {"success" => false, "error" => "No native handle"} unless native
          options = parse_print_options(opts)
          {"success" => p.print_to_pdf(native, path, options)}
        end

        context.command "printing.list_printers" do
          {"printers" => p.list_printers}
        end

        context.command "printing.show_dialog", JSON::Any do |opts|
          wv = context.app.primary_window
          next {"success" => false, "error" => "No window"} unless wv
          native = wv.native_handle(::Webview::NativeHandleKind::BROWSER_CONTROLLER)
          next {"success" => false, "error" => "No native handle"} unless native
          options = parse_print_options(opts)
          {"success" => p.show_dialog(native, options)}
        end
      end

      # :nodoc:
      private def parse_print_options(json : JSON::Any) : Features::PrintOptions
        return Features::PrintOptions.new if json.raw.nil? || !json.raw.is_a?(Hash)
        obj = json.as_h
        Features::PrintOptions.new(
          copies: obj["copies"]?.try(&.as_i) || 1,
          landscape: obj["landscape"]?.try(&.as_bool) || false,
          color: obj["color"]?.try(&.as_bool) || true,
          paper_size: obj["paper_size"]?.try(&.as_s) || "A4",
          scale: obj["scale"]?.try(&.as_f) || 1.0,
          margins_top: obj["margins_top"]?.try(&.as_f) || 20.0,
          margins_right: obj["margins_right"]?.try(&.as_f) || 20.0,
          margins_bottom: obj["margins_bottom"]?.try(&.as_f) || 20.0,
          margins_left: obj["margins_left"]?.try(&.as_f) || 20.0,
          header: obj["header"]?.try(&.as_s),
          footer: obj["footer"]?.try(&.as_s),
          output_path: obj["output_path"]?.try(&.as_s),
        )
      end
    end
  end
end
