require "../../../src/app/app"

# Notes — quick markdown-capable notes with color labels and archive.
# Backed by the in-memory DevStation::Store (non-persistent).
module DevStation::Notes
  extend self

  def setup(app : CrystKit::App, store : DevStation::Store) : Nil
    # ── Create ─────────────────────────────────────────────────────────────
    app.async "notes.create", String, String, String do |title, content, color, _cancel|
      store.create_note(title, content, color)
    end

    # ── Update ─────────────────────────────────────────────────────────────
    app.async "notes.update", Int32, String, String, String do |id, title, content, color, _cancel|
      store.update_note(id.to_i64, title, content, color)
    end

    # ── Delete ─────────────────────────────────────────────────────────────
    app.async "notes.delete", Int32 do |id, _cancel|
      store.delete_note(id.to_i64)
      "ok"
    end

    # ── Archive/unarchive ─────────────────────────────────────────────────
    app.async "notes.toggle_archive", Int32 do |id, _cancel|
      {"archived" => store.toggle_note_archive(id.to_i64)}
    end

    # ── List notes ─────────────────────────────────────────────────────────
    app.async "notes.list", Bool do |include_archived, _cancel|
      store.list_notes(include_archived)
    end

    # ── Get full note ─────────────────────────────────────────────────────
    app.async "notes.get", Int32 do |id, _cancel|
      store.get_note(id.to_i64)
    end

    # ── Search ───────────────────────────────────────────────────────────
    app.async "notes.search", String do |query, _cancel|
      store.search_notes(query)
    end

    # ── Stats ────────────────────────────────────────────────────────────
    app.async "notes.stats" do
      store.note_stats
    end
  end
end
