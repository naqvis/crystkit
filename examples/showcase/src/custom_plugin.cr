require "../../../src/plugins/base"

# A custom plugin demonstrating the full plugin protocol:
#
#   - Inherits CrystKit::Plugin::Base
#   - Declares dependencies (must run after fs and store)
#   - Hooks into `initialize_plugin` to register IPC commands
#   - Hooks into `cleanup_plugin` to flush state on shutdown
#   - Subscribes to backend events from other plugins / the app
#   - Persists state via the Store plugin (no manual file I/O)
#
# Recents tracks the last 25 file paths the user opened or saved through
# the Dialog plugin (or any code that emits `recents:track`). The
# frontend can read or clear the list via IPC.
class RecentsPlugin < CrystKit::Plugin::Base
  MAX_ENTRIES = 25
  STORE_NS    = "recents"
  STORE_KEY   = "list"

  @recents : Array(String) = [] of String
  @ctx : CrystKit::Plugin::Context? = nil

  def identifier : String
    "recents"
  end

  def metadata : CrystKit::Plugin::Metadata
    CrystKit::Plugin::Metadata.new(
      identifier,
      dependencies: ["store"],
      commands: %w(recents.list recents.clear recents.remove),
    )
  end

  def initialize_plugin(context : CrystKit::Plugin::Context) : Nil
    @ctx = context

    # Hydrate from disk via the Store plugin's IPC layer.
    raw = context.app.router.invoke_command(
      "store.get",
      JSON.parse(%([#{STORE_NS.to_json},#{STORE_KEY.to_json}]))
    )
    if arr = raw.as_a?
      @recents = arr.map(&.as_s)
    end

    # Backend → backend event: any code can emit this to add a path.
    context.app.on("recents:track") do |payload|
      if path = payload.as_h?.try(&.["path"]?.try(&.as_s?))
        track(path)
      end
    end

    # Frontend-callable commands.
    context.command "recents.list" do
      @recents.dup
    end

    context.command "recents.clear" do
      @recents.clear
      persist
      "ok"
    end

    context.command "recents.remove", String do |path|
      @recents.delete(path)
      persist
      "ok"
    end
  end

  def cleanup_plugin : Nil
    persist
  end

  private def track(path : String) : Nil
    @recents.delete(path)
    @recents.unshift(path)
    @recents = @recents.first(MAX_ENTRIES)
    persist
    @ctx.try(&.app.emit("recents:changed", {"recents" => @recents}))
  end

  private def persist : Nil
    return unless ctx = @ctx
    ctx.app.router.invoke_command(
      "store.set",
      JSON.parse(%([#{STORE_NS.to_json},#{STORE_KEY.to_json},#{@recents.to_json}]))
    )
  end
end
