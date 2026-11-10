require "../../../src/app/app"

# Snippets — code snippet manager with search, tags, and pin support.
# Backed by the in-memory DevStation::Store (non-persistent).
module DevStation::Snippets
  extend self

  def setup(app : CrystKit::App, store : DevStation::Store) : Nil
    # ── Create snippet ────────────────────────────────────────────────────
    app.async "snippets.create", String, String, String, String do |title, language, content, tags, _cancel|
      store.create_snippet(title, language, content, tags)
    end

    # ── Update snippet ────────────────────────────────────────────────────
    app.async "snippets.update", Int32, String, String, String, String do |id, title, language, content, tags, _cancel|
      store.update_snippet(id.to_i64, title, language, content, tags)
    end

    # ── Delete snippet ────────────────────────────────────────────────────
    app.async "snippets.delete", Int32 do |id, _cancel|
      store.delete_snippet(id.to_i64)
      "ok"
    end

    # ── Toggle pin ────────────────────────────────────────────────────────
    app.async "snippets.toggle_pin", Int32 do |id, _cancel|
      {"pinned" => store.toggle_snippet_pin(id.to_i64)}
    end

    # ── List snippets (with optional language filter) ─────────────────────
    app.async "snippets.list", String do |language, _cancel|
      store.list_snippets(language)
    end

    # ── Get full snippet (including content) ──────────────────────────────
    app.async "snippets.get", Int32 do |id, _cancel|
      store.get_snippet(id.to_i64)
    end

    # ── Search ──────────────────────────────────────────────────────────
    app.async "snippets.search", String do |query, _cancel|
      store.search_snippets(query)
    end

    # ── List all distinct languages in use ────────────────────────────────
    app.async "snippets.languages" do
      store.snippet_languages
    end

    # ── Import from clipboard (smart language detect by extension hint) ───
    app.async "snippets.import_text", String, String, String do |title, content, lang_hint, _cancel|
      language = lang_hint.empty? ? detect_language(content) : lang_hint
      store.import_snippet(title, language, content)
    end

    # ── Statistics ────────────────────────────────────────────────────────
    app.async "snippets.stats" do
      store.snippet_stats
    end
  end

  private def detect_language(content : String) : String
    return "crystal" if content.includes?("require \"") && content.includes?(" do")
    return "javascript" if content.includes?("const ") || content.includes?("function ")
    return "typescript" if content.includes?(": string") || content.includes?("interface ")
    return "python" if content.includes?("def ") && content.includes?("import ")
    return "ruby" if content.includes?("def ") && content.includes?("end")
    return "rust" if content.includes?("fn ") && content.includes?("let mut")
    return "go" if content.includes?("func ") && content.includes?("package ")
    return "css" if content.includes?("{") && content.includes?(":") && !content.includes?("\"")
    return "html" if content.includes?("<html") || content.includes?("<!doctype")
    return "json" if content.strip.starts_with?("{") || content.strip.starts_with?("[")
    return "sql" if content.upcase.includes?("SELECT ") || content.upcase.includes?("CREATE TABLE")
    "plaintext"
  end
end
