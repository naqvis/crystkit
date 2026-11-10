require "../../../src/app/app"
require "../../../src/features/fs"
require "../../../src/features/file_watcher"
require "../../../src/features/dialog"

# File Explorer — a proper file browser with live watch, read/write, and
# multi-tab file editing. Integrates with Snippets for quick import.
module DevStation::FileExplorer
  extend self

  @@watchers = {} of String => String # watch_id -> path
  @@watchers_lock = Mutex.new

  def setup(app : CrystKit::App, store : DevStation::Store) : Nil
    fs = CrystKit::Features::FileSystem.new(app.security)
    # Explorer refreshes the directory currently on screen. A recursive watch
    # of $HOME is both unnecessary and prohibitively expensive on large trees.
    watcher = CrystKit::Features::FileWatcher.new
    app.on_shutdown do
      @@watchers_lock.synchronize { @@watchers.clear }
      watcher.close
    end
    dialog = CrystKit::Features::FileDialog.new(app.security)

    # ── List directory ────────────────────────────────────────────────────
    app.async "explorer.list", String do |path, _cancel|
      target = path.empty? ? (ENV["HOME"]? || ENV["USERPROFILE"]? || Dir.current) : path
      begin
        entries = fs.list_dir(Path[target])
        sorted = entries.sort_by { |e| {e.type.to_s == "directory" ? 0 : 1, e.name.downcase} }
        {
          "path"    => target,
          "entries" => sorted.map { |e|
            {
              "name"        => e.name,
              "path"        => e.path.to_s,
              "type"        => e.type.to_s.downcase,
              "size"        => e.size,
              "modified_at" => e.modified_at.to_rfc3339,
            }
          },
        }
      rescue ex
        {"path" => target, "entries" => [] of String, "error" => ex.message}
      end
    end

    # ── Read file content ─────────────────────────────────────────────────
    app.async "explorer.read", String do |path, _cancel|
      begin
        content = fs.read_text(Path[path])
        size = File.size(path)
        ext = File.extname(path).lstrip(".")
        {
          "path"     => path,
          "content"  => content,
          "size"     => size,
          "language" => ext_to_language(ext),
          "ok"       => true,
        }
      rescue ex
        {"path" => path, "content" => "", "ok" => false, "error" => ex.message}
      end
    end

    # ── Write file content ────────────────────────────────────────────────
    app.async "explorer.write", String, String do |path, content, _cancel|
      fs.write_text(Path[path], content)
      {"ok" => true, "size" => content.bytesize}
    end

    # ── File metadata ─────────────────────────────────────────────────────
    app.async "explorer.metadata", String do |path, _cancel|
      begin
        m = fs.metadata(Path[path])
        {
          "size"        => m.size,
          "created_at"  => m.created_at.to_rfc3339,
          "modified_at" => m.modified_at.to_rfc3339,
          "permissions" => m.permissions.to_s(8),
          "ok"          => true,
        }
      rescue ex
        {"ok" => false, "error" => ex.message}
      end
    end

    # ── Create file or directory ───────────────────────────────────────────
    app.async "explorer.create", String, String do |path, kind, _cancel|
      if kind == "directory"
        fs.create_dir(Path[path], recursive: true)
      else
        fs.write_text(Path[path], "")
      end
      "ok"
    end

    # ── Delete ────────────────────────────────────────────────────────────
    app.async "explorer.delete", String do |path, _cancel|
      fs.remove_file(Path[path])
      "ok"
    end

    # ── Rename/move ───────────────────────────────────────────────────────
    app.async "explorer.move", String, String do |source, dest, _cancel|
      fs.move(Path[source], Path[dest])
      "ok"
    end

    # ── Open native file dialog ───────────────────────────────────────────
    app.async "explorer.open_dialog", String do |title, _cancel|
      opts = CrystKit::Features::OpenFileOptions.new(title: title.empty? ? "Open File" : title)
      path = dialog.open_file(opts)
      path ? {"path" => path.to_s, "picked" => true} : {"path" => "", "picked" => false}
    end

    # ── Open folder dialog ────────────────────────────────────────────────
    app.async "explorer.open_folder", String do |title, _cancel|
      opts = CrystKit::Features::FolderOptions.new(title: title.empty? ? "Open Folder" : title)
      path = dialog.select_folder(opts)
      path ? {"path" => path.to_s, "picked" => true} : {"path" => "", "picked" => false}
    end

    # ── Save file dialog ──────────────────────────────────────────────────
    app.async "explorer.save_dialog", String do |default_name, _cancel|
      opts = CrystKit::Features::SaveFileOptions.new(default_name: default_name)
      path = dialog.save_file(opts)
      path ? {"path" => path.to_s, "picked" => true} : {"path" => "", "picked" => false}
    end

    # ── Watch a directory for changes ─────────────────────────────────────
    app.async "explorer.watch", String, String do |watch_id, path, _cancel|
      # Unwatch any existing watcher for this id
      ch = @@watchers_lock.synchronize do
        if old = @@watchers[watch_id]?
          watcher.unwatch(old) rescue nil
        end
        channel = watcher.watch(path)
        @@watchers[watch_id] = path
        channel
      end

      # Drain the channel in a background fiber
      spawn(name: "explorer-watch-#{watch_id}") do
        loop do
          event = ch.receive?
          break unless event
          app.emit("explorer:change", {
            "watch_id"  => watch_id,
            "path"      => event.path,
            "old_path"  => event.old_path,
            "kind"      => event.type,
            "timestamp" => Time.utc.to_unix_ms,
          })
        end
      end

      {"watching" => path}
    end

    # ── Unwatch ───────────────────────────────────────────────────────────
    app.command "explorer.unwatch", String do |watch_id|
      path = @@watchers_lock.synchronize { @@watchers.delete(watch_id) }
      if path
        watcher.unwatch(path) rescue nil
      end
      "ok"
    end

    # ── Search files by name ──────────────────────────────────────────────
    app.async "explorer.search_files", String, String, timeout: 15.seconds do |root, query, _cancel|
      results = [] of Hash(String, String | Int64)
      begin
        walk(Path[root], query.downcase, results, 0)
      rescue
      end
      results.first(200)
    end
  end

  private def walk(dir : Path, query : String, results : Array(Hash(String, String | Int64)), depth : Int32) : Nil
    return if depth > 5
    Dir.each_child(dir.to_s) do |name|
      next if name.starts_with?(".")
      full = dir / name
      if Dir.exists?(full.to_s)
        walk(full, query, results, depth + 1)
      elsif name.downcase.includes?(query)
        results << {"name" => name, "path" => full.to_s, "size" => File.size(full.to_s).to_i64}
      end
    end
  rescue
    # Ignore permission errors
  end

  private def ext_to_language(ext : String) : String
    {
      "cr"   => "crystal",
      "rb"   => "ruby",
      "py"   => "python",
      "js"   => "javascript",
      "ts"   => "typescript",
      "jsx"  => "javascript",
      "tsx"  => "typescript",
      "vue"  => "html",
      "html" => "html",
      "htm"  => "html",
      "css"  => "css",
      "scss" => "scss",
      "sass" => "scss",
      "json" => "json",
      "yaml" => "yaml",
      "yml"  => "yaml",
      "toml" => "toml",
      "md"   => "markdown",
      "rs"   => "rust",
      "go"   => "go",
      "c"    => "c",
      "cpp"  => "cpp",
      "h"    => "c",
      "java" => "java",
      "kt"   => "kotlin",
      "sh"   => "shell",
      "bash" => "shell",
      "zsh"  => "shell",
      "fish" => "shell",
      "sql"  => "sql",
      "xml"  => "xml",
      "svg"  => "xml",
      "txt"  => "plaintext",
    }[ext]? || "plaintext"
  end
end
