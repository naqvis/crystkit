require "digest/sha256"
require "../../../src/features/clipboard"
require "log"

module ClipVault::Monitor
  Log = ::Log.for(self)

  @@skip_once : Bool = false

  def self.skip_once
    @@skip_once = true
  end

  struct ClipEvent
    getter id : Int32
    getter content : String
    getter preview : String
    getter content_type : String
    getter app_name : String
    getter copy_count : Int32
    getter first_copied_at : String
    getter last_copied_at : String

    def initialize(@id, @content, @preview, @content_type = "text", @app_name = "", @copy_count = 0, @first_copied_at = "", @last_copied_at = "")
    end

    def to_json_hash
      {
        "id"            => id,
        "content"       => content,
        "preview"       => preview,
        "contentType"   => content_type,
        "textContent"   => "",
        "favorite"      => 0,
        "appName"       => app_name,
        "copyCount"     => copy_count,
        "firstCopiedAt" => first_copied_at,
        "lastCopiedAt"  => last_copied_at,
      }
    end
  end

  def self.detect(clipboard)
    if img = clipboard.read_image
      {content: "", preview: "", type: "image", raw: img}
    elsif (html = clipboard.read_html) && !html.empty?
      text = clipboard.read_text
      preview = text.empty? ? "(HTML content)" : (text.size > 150 ? text[0, 150] + "…" : text)
      {content: html, preview: preview, type: "html", raw: nil}
    elsif (rtf = clipboard.read_rtf) && !rtf.empty?
      text = clipboard.read_text
      preview = text.empty? ? "(RTF content)" : (text.size > 150 ? text[0, 150] + "…" : text)
      {content: rtf, preview: preview, type: "rtf", raw: nil}
    else
      text = clipboard.read_text
      return nil if text.empty?
      preview = text.size > 150 ? text[0, 150] + "…" : text
      {content: text, preview: preview, type: "text", raw: nil}
    end
  end

  def self.start(app, store)
    clipboard = app.find_plugin(CrystKit::Plugins::Clipboard).clipboard
    storage = Path[app.config.storage_dir]
    images_dir = Store.images_dir(storage)

    clipboard.on_change {
      if @@skip_once
        @@skip_once = false
        next
      end
      spawn {
        begin
          result = detect(clipboard)
          next unless result

          if result[:type] == "image"
            img = result[:raw]
            next unless img
            hash = Digest::SHA256.hexdigest(String.new(img.data))
            app_name = CrystKit::Platform.frontmost_app_name
            row = store.upsert_image(app_name, hash)
            next unless row
            new_id = row["id"]?.try(&.as(Int32)) || 0
            count = row["copy_count"]?.try(&.as(Int32)) || 0
            last_at = row["last_copied_at"]?.try(&.as(String)) || Time.utc.to_s("%Y-%m-%d %H:%M:%S")
            if count == 1
              File.write(images_dir / "#{new_id}.png", img.data)
            end
            event = ClipEvent.new(id: new_id, content: "", preview: result[:preview], content_type: "image", app_name: app_name, copy_count: count, last_copied_at: last_at)
          else
            text = clipboard.read_text
            next if text.empty?
            hash = Digest::SHA256.hexdigest(text)

            app_name = CrystKit::Platform.frontmost_app_name
            row = store.upsert(result[:content], result[:type], result[:preview], app_name, hash)
            next unless row
            new_id = row["id"]?.try(&.as(Int32)) || 0
            count = row["copy_count"]?.try(&.as(Int32)) || 0
            last_at = row["last_copied_at"]?.try(&.as(String)) || Time.utc.to_s("%Y-%m-%d %H:%M:%S")

            store.prune if count == 1

            event = ClipEvent.new(id: new_id, content: result[:content], preview: result[:preview], content_type: result[:type], app_name: app_name, copy_count: count, last_copied_at: last_at)
          end

          app.emit("clipboard:new", event.to_json_hash)
        rescue ex
          Log.error { "Clipboard monitoring error: #{ex.message}" }
        end
      }
    }

    clipboard.start_monitoring
    Log.info { "Clipboard monitoring started" }
  end
end
