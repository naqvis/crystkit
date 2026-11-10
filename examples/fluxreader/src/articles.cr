module FluxReader::Articles
  extend self

  record ListRec, filter : String = "all", feed_id : Int64? = nil, category_id : Int64? = nil, limit : Int64 = 50_i64, offset : Int64 = 0_i64 do
    include JSON::Serializable
  end

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "articles.list", ListRec do |rec, _cancel|
      store.list_articles(rec.filter, rec.feed_id, rec.category_id, rec.limit, rec.offset)
    end

    app.async "articles.get", Int64 do |id, _cancel|
      store.get_article(id)
    end

    app.async "articles.mark_read", Int64 do |id, _cancel|
      store.mark_read(id)
    end

    app.async "articles.mark_unread", Int64 do |id, _cancel|
      store.mark_unread(id)
    end

    app.async "articles.mark_all_read", ListRec do |rec, _cancel|
      store.mark_all_read(rec.feed_id, rec.category_id)
      true
    end

    app.async "articles.toggle_favorite", Int64 do |id, _cancel|
      store.toggle_favorite(id)
    end

    app.async "articles.counts" do
      store.article_counts
    end

    app.async "articles.fetch_content", Int64, timeout: 15.seconds do |id, _cancel|
      article = store.find_article_by_id(id)
      next nil unless article
      if stored = article.content
        next stored if stored.size > 200
      end
      link = article.link
      next nil unless link

      begin
        http = app.find_plugin(CrystKit::Plugins::HTTP).client
        response = http.get(link, CrystKit::Features::RequestOptions.new(
          headers: {"User-Agent" => "FluxReader/1.0"},
        ))
        next nil unless response.success?

        doc = XML.parse_html(response.text)
        body = doc.xpath_node("//article") || doc.xpath_node("//main") || doc.xpath_node("//body")
        next nil unless body

        %w(script style nav header footer aside form).each do |tag|
          body.xpath_nodes("//#{tag}").each(&.unlink)
        end

        fetched = body.to_xml
        store.set_article_content(id, fetched)
        fetched
      rescue ex
        Log.error { "fluxreader: fetch_content failed for #{link}: #{ex.message}" }
        nil
      end
    end
  end
end
