class ClipVault::Commands
  def initialize(@store : ClipVault::Store, @storage_dir : String)
  end

  def register(app : CrystKit::App)
    app.async("clipvault.history", String?, Bool?) { |search, fav_only, _cancel| history(search, fav_only) }
    app.async("clipvault.favorite", Int32) { |id, _cancel| favorite(id) }
    app.async("clipvault.delete", Int32) { |id, _cancel| delete(id) }
    app.async("clipvault.delete_many", JSON::Any) { |ids, _cancel| delete_many(ids) }
    app.async("clipvault.clear") { clear }
    app.async("clipvault.stats") { stats }
    app.async("clipvault.image", Int32) { |id, _cancel| image(id) }
    app.command("clipvault.skip_once") { skip_once }
    app.async("clipvault.increment_copy", Int32) { |id, _cancel| increment_copy(id) }
    app.async("clipvault.export") { export }
    app.async("clipvault.import", String) { |data, _cancel| import(data) }
    app.async("clipvault.setting", String, String?) { |key, value, _cancel| setting(key, value) }
  end

  def history(search : String?, fav_only : Bool?)
    if fav_only
      @store.list_favorites
    elsif search
      @store.search(search)
    else
      @store.list_all
    end
  end

  def favorite(id : Int32)
    is_fav = @store.toggle_favorite(id)
    {"ok" => true, "favorite" => is_fav}
  end

  def delete(id : Int32)
    @store.delete(id)
    {"ok" => true}
  end

  def delete_many(ids : JSON::Any)
    raw = ids.as_a.map(&.as_i)
    @store.delete_many(raw)
    {"ok" => true}
  end

  def clear
    @store.clear_all
    {"ok" => true}
  end

  def stats
    @store.stats
  end

  def image(id : Int32)
    b64 = @store.read_image_base64(id)
    if b64
      {"data" => b64}
    else
      {"data" => ""}
    end
  end

  def skip_once
    ClipVault::Monitor.skip_once
    {"ok" => true}
  end

  def increment_copy(id : Int32)
    @store.increment_copy_count(id)
    {"ok" => true}
  end

  def export
    @store.export
  end

  def import(data : String)
    count = @store.import(data)
    {"imported" => count}
  end

  def setting(key : String, value : String?)
    if v = value
      @store.set_setting(key, v)
      {"ok" => true}
    else
      {"value" => @store.get_setting(key)}
    end
  end
end
