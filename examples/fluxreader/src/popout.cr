module FluxReader::Popout
  extend self

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "reader.popout", Int64 do |id, _cancel|
      row = store.get_article(id)
      next nil unless row
      title = row["title"]?.try(&.to_s) || "Article"
      feed = row["feed_title"]?.try(&.to_s) || ""
      content = (row["content"]? || row["summary"]?).try(&.to_s) || ""
      app.window(
        title: title,
        width: 800,
        height: 700,
        html: popout_html(title, feed, content),
        label: "popout-#{id}",
      )
      true
    end

    app.command "reader.open_window", String do |url|
      app.find_plugin(CrystKit::Plugins::External).opener.open_url(url)
      true
    end
  end

  private def popout_html(title : String, feed_title : String, content : String) : String
    etitle = escape_html(title)
    efeed_title = escape_html(feed_title)

    <<-HTML
      <!DOCTYPE html>
      <html lang="en">
      <head><meta charset="UTF-8"><title>#{etitle}</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          background: #0f0f13; color: #e8e8e8; padding: 24px 32px; line-height: 1.65; font-size: 15px;
        }
        h1 { font-size: 22px; font-weight: 700; margin-bottom: 10px; }
        .meta { color: #888; font-size: 13px; margin-bottom: 20px; }
        img { max-width: 100%; height: auto; }
        a { color: #6366f1; }
        #{sanitize_css}
      </style></head>
      <body>
        <h1>#{etitle}</h1>
        <div class="meta">#{efeed_title}</div>
        <div>#{sanitize_html(content)}</div>
      </body>
      </html>
    HTML
  end

  private def escape_html(str : String) : String
    str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;").gsub("'", "&apos;")
  end

  private def sanitize_html(html : String) : String
    html.gsub(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/i, "")
      .gsub(/<iframe\b[^<]*(?:(?!<\/iframe>)<[^<]*)*<\/iframe>/i, "")
      .gsub(/<object\b[^<]*(?:(?!<\/object>)<[^<]*)*<\/object>/i, "")
      .gsub(/<embed\b[^<]*(?:(?!<\/embed>)<[^<]*)*<\/embed>/i, "")
  end

  private def sanitize_css : String
    "img { max-width: 100%; height: auto; } a { color: #6366f1; } pre { background: #16161d; padding: 12px; border-radius: 6px; overflow-x: auto; } code { background: #16161d; padding: 2px 4px; border-radius: 3px; font-size: 0.9em; }"
  end
end
