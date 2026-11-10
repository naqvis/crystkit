require "digest/sha256"
require "json"
require "file_utils"

module ClipVault
  # In-memory clipboard history store.
  class Store
    MAX_HISTORY_DEFAULT = 500

    struct Clip
      property id : Int32
      property content : String
      property content_type : String
      property preview : String
      property favorite : Int32
      property app_name : String
      property copy_count : Int32
      property content_hash : String
      property first_copied_at : String
      property last_copied_at : String

      def initialize(@id, @content = "", @content_type = "text", @preview = "", @favorite = 0,
                     @app_name = "", @copy_count = 0, @content_hash = "", @first_copied_at = "", @last_copied_at = "")
      end

      def to_hash
        {
          "id"            => id,
          "content"       => content,
          "contentType"   => content_type,
          "preview"       => preview,
          "favorite"      => favorite,
          "appName"       => app_name,
          "copyCount"     => copy_count,
          "firstCopiedAt" => first_copied_at,
          "lastCopiedAt"  => last_copied_at,
        }
      end
    end

    @items = [] of Clip
    @settings : Hash(String, String)
    @next_id = 1
    @storage_dir : Path

    def self.open(storage_dir : Path) : Store
      new(storage_dir)
    end

    def self.images_dir(storage_dir : Path) : Path
      dir = storage_dir / "images"
      Dir.mkdir_p(dir.to_s) unless Dir.exists?(dir)
      dir
    end

    def self.image_path(storage_dir : Path, id : Int32) : Path
      images_dir(storage_dir) / "#{id}.png"
    end

    def self.make_hash(content : String, text_content : String = "") : String
      Digest::SHA256.hexdigest(text_content.empty? ? content : text_content)
    end

    def initialize(@storage_dir : Path)
      @settings = {
        "theme"      => "system",
        "max_items"  => "500",
        "auto_paste" => "false",
        "shortcut"   => "Meta+Shift+V",
      }
    end

    def close : Nil
    end

    private def now : String
      Time.utc.to_s("%Y-%m-%d %H:%M:%S")
    end

    private def image_path(id : Int32) : Path
      self.class.image_path(@storage_dir, id)
    end

    def upsert(content : String, content_type : String, preview : String, app_name : String, hash : String)
      if item = @items.find { |c| c.content_hash == hash && !hash.empty? }
        item.copy_count += 1
        item.last_copied_at = now
        {"id" => item.id, "copy_count" => item.copy_count, "last_copied_at" => item.last_copied_at}
      else
        item = Clip.new(
          id: @next_id,
          content: content,
          content_type: content_type,
          preview: preview,
          app_name: app_name,
          copy_count: 1,
          content_hash: hash,
          first_copied_at: now,
          last_copied_at: now,
        )
        @next_id += 1
        @items << item
        {"id" => item.id, "copy_count" => 1, "last_copied_at" => item.last_copied_at}
      end
    end

    def upsert_image(app_name : String, hash : String)
      upsert("", "image", "", app_name, hash)
    end

    def increment_copy_count(id : Int32) : Nil
      if item = @items.find { |c| c.id == id }
        item.copy_count += 1
        item.last_copied_at = now
      end
    end

    def search(query : String, limit : Int32 = 200)
      @items.select { |c| c.content.includes?(query) || c.preview.includes?(query) }
        .sort { |a, b| sort_cmp(a, b) }
        .first(limit).map(&.to_hash)
    end

    def list_all(limit : Int32 = 200)
      @items.sort { |a, b| sort_cmp(a, b) }.first(limit).map(&.to_hash)
    end

    def list_favorites(limit : Int32 = 200)
      @items.select { |c| c.favorite == 1 }
        .sort { |a, b| b.last_copied_at <=> a.last_copied_at }
        .first(limit).map(&.to_hash)
    end

    def toggle_favorite(id : Int32) : Bool
      item = @items.find { |c| c.id == id }
      return false unless item
      item.favorite = item.favorite == 1 ? 0 : 1
      item.favorite == 1
    end

    def delete(id : Int32) : Nil
      @items.reject! { |c| c.id == id }
    end

    def delete_many(ids : Array(Int32)) : Nil
      @items.reject! { |c| ids.includes?(c.id) }
    end

    def clear_all : Nil
      @items.clear
    end

    def stats
      total = @items.size
      fav = @items.count { |c| c.favorite == 1 }
      {"total" => total, "favorite" => fav}
    end

    def read_image_base64(id : Int32) : String?
      path = image_path(id)
      return nil unless File.exists?(path)
      slice = Bytes.new(File.size(path))
      File.open(path, "rb", &.read_fully(slice))
      Base64.strict_encode(slice)
    end

    def export
      @items.sort_by(&.id).map(&.to_hash)
    end

    def import(json_data : String) : Int32
      parsed = JSON.parse(json_data)
      count = 0
      parsed.as_a.each do |item|
        content = item["content"]?.try(&.as_s) || ""
        next if content.empty?
        ctype = item["contentType"]?.try(&.as_s) || "text"
        app_name = item["appName"]?.try(&.as_s) || ""
        fav = item["favorite"]?.try(&.as_i) || 0
        copy_count = item["copyCount"]?.try(&.as_i) || 0
        first_at = item["firstCopiedAt"]?.try(&.as_s) || now
        last_at = item["lastCopiedAt"]?.try(&.as_s) || first_at
        text_content = item["textContent"]?.try(&.as_s) || ""
        hash = self.class.make_hash(content, text_content)
        preview = build_preview(text_content.empty? ? content : text_content)
        @items << Clip.new(
          id: @next_id, content: content, content_type: ctype, preview: preview,
          favorite: fav, app_name: app_name, copy_count: copy_count,
          content_hash: hash, first_copied_at: first_at, last_copied_at: last_at
        )
        @next_id += 1
        count += 1
      end
      prune
      count
    end

    def get_setting(key : String, default = "") : String
      @settings[key]? || default
    end

    def set_setting(key : String, value : String) : Nil
      @settings[key] = value
    end

    def prune : Nil
      max = get_setting("max_items", MAX_HISTORY_DEFAULT.to_s).to_i? || MAX_HISTORY_DEFAULT
      return if @items.size <= max
      keep_ids = @items.sort { |a, b| sort_cmp(a, b) }.first(max).map(&.id)
      @items.reject! { |c| !keep_ids.includes?(c.id) }
    end

    private def sort_cmp(a : Clip, b : Clip) : Int32
      c = b.favorite <=> a.favorite
      c == 0 ? (b.last_copied_at <=> a.last_copied_at) : c
    end

    private def build_preview(content : String) : String
      content.size > 150 ? content[0, 150] + "…" : content
    end
  end
end
