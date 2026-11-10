require "base64"
require "../base"
require "../../features/clipboard"

module CrystKit
  module Plugins
    # Plugin exposing the system clipboard to the frontend for text, HTML, and
    # image interchange.
    #
    # Registers IPC commands:
    #   clipboard:read_text,   clipboard:write_text,
    #   clipboard:read_html,   clipboard:write_html,
    #   clipboard:write_image
    #
    # Required capabilities: clipboard:read, clipboard:write
    #
    # ```
    # app.plugin(CrystKit::Plugins::Clipboard.new)
    # ```
    class Clipboard < Plugin::Base
      Log = ::Log.for(self)
      getter! clipboard : Features::Clipboard

      def identifier : String
        "clipboard"
      end

      def metadata : Plugin::Metadata
        ipc = IPC::PolicyCatalog.new
          .require(%w(clipboard.read_text clipboard.read_html clipboard.read_image clipboard.read_rtf), "clipboard:read")
          .require(%w(clipboard.write_text clipboard.write_html clipboard.write_image clipboard.write_rtf clipboard.clear), "clipboard:write")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(clipboard:read clipboard:write),
          commands: %w(clipboard.read_text clipboard.write_text clipboard.read_html clipboard.write_html clipboard.read_image clipboard.write_image clipboard.read_rtf clipboard.write_rtf clipboard.clear),
          ipc: ipc,
        )
      end

      # The write commands return `"ok"` on success. `clipboard.write_image`
      # expects a Base64-encoded PNG string.
      def initialize_plugin(context : Plugin::Context) : Nil
        @clipboard = cb = Features::Clipboard.new(context.capabilities)

        context.command "clipboard.read_text" do
          cb.read_text
        end

        context.command "clipboard.write_text", String do |text|
          cb.write_text(text)
          "ok"
        end

        context.command "clipboard.read_html" do
          cb.read_html
        end

        context.command "clipboard.write_html", String do |html|
          cb.write_html(html)
          "ok"
        end

        context.command "clipboard.write_image", String do |base64_data|
          image_data = Base64.decode(base64_data)
          cb.write_image(Features::ClipboardImage.new(image_data, 0, 0, Features::ImageFormat::PNG))
          "ok"
        end

        context.command "clipboard.read_image" do
          cb.read_image.try { |img| Base64.encode(img.data) }
        end

        context.command "clipboard.read_rtf" do
          cb.read_rtf
        end

        context.command "clipboard.write_rtf", String do |rtf|
          cb.write_rtf(rtf)
          "ok"
        end

        context.command "clipboard.clear" do
          cb.clear
          "ok"
        end
      end

      def cleanup_plugin : Nil
        clipboard.stop_monitoring
      rescue ex
        Log.warn(exception: ex) { "Clipboard cleanup failed" }
      end
    end
  end
end
