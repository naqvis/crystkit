require "digest/sha256"
require "wait_group"
require "../../src/crystkit"

struct DirEntry
  include JSON::Serializable

  getter name : String
  getter path : String
  getter type : String
  property size : Int64
  getter modified_at : String?
  property children : Array(DirEntry)?

  def initialize(@name, @path, @type, @size, @modified_at, @children)
  end
end

class ScanStatus
  include JSON::Serializable

  property status : String = "idle"
  property current_path : String = ""
  property files_scanned : Int64 = 0_i64
  property elapsed : Float64 = 0.0

  def initialize; end
end

struct DuplicateGroup
  include JSON::Serializable

  getter hash : String
  getter size : Int64
  getter files : Array(String)

  def initialize(@hash, @size, @files)
  end
end

class DiskPiePlugin < CrystKit::Plugin::Base
  getter! fs : CrystKit::Features::FileSystem
  getter! system_info : CrystKit::Features::SystemInfo
  @scan_status : CrystKit::State::Slice(ScanStatus)?

  def initialize(@scan_status : CrystKit::State::Slice(ScanStatus)? = nil)
  end

  def identifier : String
    "diskpie"
  end

  def metadata : CrystKit::Plugin::Metadata
    ipc = CrystKit::IPC::PolicyCatalog.new
      .require(%w(diskpie.list_mounts diskpie.scan diskpie.list_dir diskpie.measure), "system:read")
      .require("diskpie.trash_paths", "fs:delete")
      .require("diskpie.find_duplicates", "fs:read")

    CrystKit::Plugin::Metadata.new(
      identifier,
      capabilities: %w(system:read fs:delete),
      commands: %w(diskpie.list_mounts diskpie.scan diskpie.list_dir diskpie.measure diskpie.trash_paths diskpie.find_duplicates),
      ipc: ipc,
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    @fs = CrystKit::Features::FileSystem.new(context.security)
    @system_info = CrystKit::Features::SystemInfo.new

    context.command "diskpie.list_mounts" do
      system_info.list_mounts
    end

    context.async "diskpie.scan", String, timeout: 1.hour do |path|
      scan_start = Time.instant
      update_status { |s| s.status = "scanning"; s.current_path = path; s.files_scanned = 0; s.elapsed = 0.0 }
      result = scan_tree(path)
      elapsed = (Time.instant - scan_start).total_seconds
      update_status { |s| s.status = "done"; s.current_path = path; s.elapsed = elapsed }
      result
    end

    # Instant browse: returns ONLY the direct children of *path* (no recursion).
    # File sizes are accurate; directory sizes are 0 (cumulative size is not
    # filesystem metadata and must be measured separately via `diskpie.measure`).
    context.command "diskpie.list_dir", String do |path|
      abs = Path[path].expand(home: true)
      name = File.basename(abs.to_s)
      info = fs.metadata(abs)
      children = [] of DirEntry
      fs.list_dir(abs).each do |entry|
        # Directory sizes are 0 here: cumulative size is unknown until measured.
        # (entry.size for a dir is just its inode/metadata size, which is meaningless.)
        dir = entry.type.directory?
        children << DirEntry.new(
          entry.name,
          entry.path.to_s,
          dir ? "directory" : "file",
          dir ? 0_i64 : entry.size,
          entry.modified_at.to_s("%Y-%m-%d %H:%M:%S"),
          nil,
        )
      end
      children.sort! { |a, b| b.size <=> a.size }
      DirEntry.new(
        name,
        abs.to_s,
        "directory",
        0_i64,
        info.modified_at.to_s("%Y-%m-%d %H:%M:%S"),
        children,
      )
    rescue ex
      Log.warn { "diskpie: list_dir failed for #{path}: #{ex.message}" }
      DirEntry.new(File.basename(path), path, "directory", 0_i64, nil, [] of DirEntry)
    end

    # Bounded-depth measure. Walks the subtree of *path* up to *max_depth*
    # levels using a fixed worker pool (one fiber per directory, capped) so
    # large trees scan concurrently across OS threads. Depth 1 (default)
    # gives real, comparable sizes for the direct children of *path* cheaply;
    # depth >= total tree size triggers a full walk (used by Find Duplicates
    # and the explicit "measure folder" action).
    context.async "diskpie.measure", String, Int32, timeout: 1.hour do |path, max_depth|
      measure_tree(Path[path].expand(home: true), Math.max(max_depth, 1_i32))
    end

    context.async "diskpie.trash_paths", Array(String) do |paths|
      trash_paths(fs, paths)
    end

    context.async "diskpie.find_duplicates", String, timeout: 1.hour do |path|
      find_duplicates(fs, path)
    end
  end

  private def update_status(&block : ScanStatus ->)
    @scan_status.try &.update { |state| block.call(state); state }
  end

  private def scan_tree(path : String) : DirEntry
    abs = Path[path].expand(home: true)
    name = File.basename(abs.to_s)
    scan_dir(abs, name)
  end

  private def scan_dir(path : Path, name : String) : DirEntry
    info = fs.metadata(path)
    update_status(&.current_path = path.to_s)

    children = [] of DirEntry
    total = 0_i64
    count = 0_i64

    begin
      fs.list_dir(path).each do |entry|
        child_path = entry.path
        begin
          if entry.type.directory?
            child = scan_dir(child_path, entry.name)
            children << child
            total += child.size
          else
            children << DirEntry.new(
              entry.name,
              child_path.to_s,
              "file",
              entry.size,
              entry.modified_at.to_s("%Y-%m-%d %H:%M:%S"),
              nil
            )
            total += entry.size
          end
          count += 1
          update_status(&.files_scanned = count) if count % 250 == 0
        rescue ex
          Log.warn { "diskpie: could not scan #{child_path}: #{ex.message}" }
        end
      end
    rescue ex
      Log.warn { "diskpie: could not list #{path}: #{ex.message}" }
    end

    children.sort! { |a, b| b.size <=> a.size }
    DirEntry.new(
      name,
      path.to_s,
      "directory",
      total,
      info.modified_at.to_s("%Y-%m-%d %H:%M:%S"),
      children
    )
  end

  # Depth-bounded parallel measure. Spawns a fixed worker pool (one fiber
  # per directory, capped at `min(cpu_count, 16)`) pulling a directory
  # work queue. Each worker scans ONE directory's immediate children:
  #   * files  -> size is known from the listing
  #   * subdirs -> enqueued for another worker (up to *max_depth* levels)
  # Because a directory is enqueued exactly once and only its own worker
  # attaches its children, the resulting tree needs no cross-fiber locking.
  # A directory's cumulative size is the sum of its direct children's
  # already-known sizes, so by the time a worker builds a node its kids
  # (and their sizes) already exist in the shared map.
  private def measure_tree(root : Path, max_depth : Int32) : DirEntry
    results = {} of String => DirEntry
    lock = Sync::Mutex.new
    queue = Channel({Path, Int32}).new(32)
    wg = WaitGroup.new
    scanned = Atomic(Int64).new(0)
    update_status { |s| s.status = "scanning"; s.current_path = root.to_s; s.files_scanned = 0; s.elapsed = 0.0 }

    # Depth travels with the path so no shared hash is touched by workers.
    # WaitGroup tracks outstanding work: +1 per enqueued directory, -1 when
    # a worker finishes it. Seed the root, then wait for the pool to drain.
    wg.add(1)
    queue.send({root, 1_i32})

    workers = (0...pool_size).map do |_|
      spawn do
        loop do
          msg = queue.receive?
          break unless msg
          path, depth = msg
          node = build_node(path, depth, max_depth, queue, wg, results, lock, scanned)
          lock.synchronize { results[path.to_s] = node }
          wg.done
        end
      end
    end

    wg.wait
    queue.close

    # Post-pass: rebuild the tree with correct cumulative sizes. Files have
    # real sizes; measured subdirs contribute their own summed totals;
    # unmeasured subdirs remain 0.
    root_node = results[root.to_s]?
    if root_node
      root_node = summarize(root_node, results)
    end

    elapsed = 0.0
    update_status { |s| s.status = "done"; s.current_path = root.to_s; s.elapsed = elapsed }
    root_node || DirEntry.new(File.basename(root.to_s), root.to_s, "directory", 0_i64, nil, [] of DirEntry)
  end

  # Recursively sums each directory node's size from its children and returns
  # a rebuilt node with correct cumulative sizes. Children of a node are all
  # present (built by workers); a directory child with no entry in *results*
  # was left unmeasured (size 0).
  private def summarize(node : DirEntry, results : Hash(String, DirEntry)) : DirEntry
    return node unless node.children
    total = 0_i64
    finalized = [] of DirEntry
    node.children.try &.each do |c|
      if c.type == "directory"
        child = results[c.path]?
        sub_node = child ? summarize(child, results) : c
        finalized << DirEntry.new(c.name, c.path, "directory", sub_node.size, c.modified_at, sub_node.children)
        total += sub_node.size
      else
        finalized << c
        total += c.size
      end
    end
    # info.size (the node's own entry size) is negligible; use children sum.
    DirEntry.new(node.name, node.path, "directory", total, node.modified_at, finalized)
  end

  # Builds the DirEntry for a single directory: lists immediate children,
  # records file sizes directly, and enqueues subdirectories (with depth+1)
  # for other workers while within *max_depth*. Directory children get a
  # placeholder size of 0 — their true cumulative size is filled in by the
  # post-pass in #measure_tree once every node has been built.
  private def build_node(path : Path, depth : Int32, max_depth : Int32,
                         queue : Channel({Path, Int32}), wg : WaitGroup,
                         results : Hash(String, DirEntry),
                         lock : Mutex, scanned : Atomic(Int64)) : DirEntry
    info = fs.metadata(path)
    update_status(&.current_path = path.to_s)
    children = [] of DirEntry
    # A directory's own inode size is meaningless; cumulative size = children sum.
    total = 0_i64
    count = 0_i64

    begin
      fs.list_dir(path).each do |entry|
        child_path = entry.path
        begin
          if entry.type.directory?
            if depth < max_depth
              wg.add(1)
              queue.send({child_path, depth + 1})
              children << DirEntry.new(
                entry.name, child_path.to_s, "directory", 0_i64,
                entry.modified_at.to_s("%Y-%m-%d %H:%M:%S"), nil)
            else
              # At max depth: report the dir with only its own file sizes.
              sub = fs.list_dir(child_path).select(&.type.file?).sum(&.size)
              children << DirEntry.new(
                entry.name, child_path.to_s, "directory", sub,
                entry.modified_at.to_s("%Y-%m-%d %H:%M:%S"), nil)
              total += sub
            end
          else
            children << DirEntry.new(
              entry.name, child_path.to_s, "file", entry.size,
              entry.modified_at.to_s("%Y-%m-%d %H:%M:%S"), nil)
            total += entry.size
          end
          count += 1
          scanned.add(1)
          update_status(&.files_scanned = scanned.get) if count % 250 == 0
        rescue ex
          Log.warn { "diskpie: could not scan #{child_path}: #{ex.message}" }
        end
      end
    rescue ex
      Log.warn { "diskpie: could not list #{path}: #{ex.message}" }
    end

    children.sort! { |a, b| b.size <=> a.size }
    DirEntry.new(
      File.basename(path.to_s), path.to_s, "directory", total,
      info.modified_at.to_s("%Y-%m-%d %H:%M:%S"), children)
  end

  private def pool_size : Int32
    n = System.cpu_count
    n = 1 if n < 1
    Math.min(n, 16).to_i32
  end

  private def trash_paths(fs : CrystKit::Features::FileSystem, paths : Array(String)) : Hash(String, Array(String))
    trashed = [] of String
    failed = [] of String

    paths.each do |p|
      begin
        path = Path[p].expand(home: true)
        fs.trash_delete(path)
        trashed << p
      rescue ex
        failed << "#{p}: #{ex.message}"
      end
    end

    {"trashed" => trashed, "failed" => failed}
  end

  private def find_duplicates(fs : CrystKit::Features::FileSystem, path : String) : Array(DuplicateGroup)
    abs = Path[path].expand(home: true)

    files_by_size = Hash(Int64, Array(String)).new
    collect_files(fs, abs, files_by_size)

    hash_groups = Hash(String, Array(String)).new
    files_by_size.each do |size, paths|
      next if paths.size < 2
      paths.each do |file_path|
        begin
          hash = hash_file(file_path)
          hash_groups[hash] ||= [] of String
          hash_groups[hash] << file_path
        rescue ex
          Log.warn { "diskpie: failed to hash #{file_path}: #{ex.message}" }
        end
      end
    end

    groups = [] of DuplicateGroup
    hash_groups.each do |hash, dup_files|
      next if dup_files.size < 2
      size = File.info(dup_files.first).size
      groups << DuplicateGroup.new(hash: hash[0..15], size: size, files: dup_files)
    end

    groups.sort_by! { |g| -(g.size * (g.files.size - 1)) }
  end

  private def collect_files(fs, path, acc : Hash(Int64, Array(String)))
    fs.list_dir(path).each do |entry|
      if entry.type.file?
        acc[entry.size] ||= [] of String
        acc[entry.size] << entry.path.to_s
      elsif entry.type.directory?
        collect_files(fs, entry.path, acc)
      end
    end
  rescue ex
    Log.warn { "diskpie: could not list #{path}: #{ex.message}" }
  end

  private def hash_file(path : String) : String
    digest = Digest::SHA256.new
    File.open(path, "r") do |io|
      buffer = Bytes.new(8192)
      while (bytes_read = io.read(buffer)) > 0
        digest.update(buffer[0, bytes_read])
      end
    end
    digest.hexfinal
  end
end

# ── App configuration ───────────────────────────────────────────────────────
config = CrystKit::AppConfig.new(
  name: "DiskPie",
  version: "1.0.0",
  identifier: "dev.crystkit.disckpie",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/assets",
)

Log.setup do |c|
  c.bind "*", :info, ::Log::IOBackend.new(STDERR)
end

app = CrystKit::App.new(config)

# ── Scan status state slice ───────────────────────────────────────────────────
scan_status = app.state("scan_status", ScanStatus) { ScanStatus.new }

# ── Built-in plugins ──────────────────────────────────────────────────────────
app
  .plugin(CrystKit::Plugins::FS.new)
  .plugin(CrystKit::Plugins::Dialog.new)
  .plugin(CrystKit::Plugins::External.new)
  .plugin(CrystKit::Plugins::MenuBar.new)
  .plugin(DiskPiePlugin.new(scan_status))

# ── Context menu ──────────────────────────────────────────────────────────
cm = CrystKit::Features::ContextMenu.new

cm.on_context("disk-list") do |b|
  b.add("Select Folder…", "ctx-select-folder")
  b.add_separator
  b.add("Rescan All", "ctx-rescan-all")
end

cm.on_context("disk-detail") do |b|
  b.add("Open", "ctx-open")
  b.add("Show in Folder", "ctx-show-in-folder")
  b.add_separator
  b.add("Copy Path", "ctx-copy-path")
  b.add_separator
  b.add("Measure Folder", "ctx-measure")
  b.add("Delete…", "ctx-delete")
  b.add_separator
  b.add("Rescan", "ctx-rescan")
end

# ── IPC commands ──────────────────────────────────────────────────────────────
app.command "app.quit" do
  app.primary_window.try(&.minimize_to_tray=(false))
  app.quit
end

# ── Main window ───────────────────────────────────────────────────────────────
app.window(
  title: "DiskPie",
  width: 1150,
  height: 780,
  debug: false,
  label: "main"
)

# ── System tray ───────────────────────────────────────────────────────────────

app.tray do |t|
  t.menu do |m|
    m.add_item("show", "Show DiskPie") { app.primary_window.try(&.show) }
    m.add_separator
    m.add_item("select-folder", "Select Folder...") do
      app.emit("tray.action", app.coerce_to_json({"action" => "select-folder"}))
    end
    m.add_separator
    m.add_item("quit", "Quit") do
      app.primary_window.try(&.minimize_to_tray=(false))
      app.quit
    end
  end

  t.create("tray.png", tooltip: "DiskPie")
  app.primary_window.try(&.minimize_to_tray = true)

  t.on_click { |btn| app.primary_window.try(&.show) if btn.left? }
end

app.run
