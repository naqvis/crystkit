module FluxReader::Feeds
  extend self

  Categories = {} of String => Int64

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "feeds.list" do
      store.list_feeds
    end

    app.async "feeds.add", String, String? do |url, category, _cancel|
      cat_id = ensure_category(store, category || "Feed")
      feed_row = store.add_feed(url, url, cat_id)
      id = feed_row["id"].as(Int64)
      spawn { Fetcher.refresh_one(app, store, id, url, nil) }
      feed_row
    end

    app.async "feeds.remove", Int64 do |id, _cancel|
      store.remove_feed(id)
      true
    end

    app.async "feeds.set_category", Int64, String do |feed_id, category, _cancel|
      cat_id = ensure_category(store, category)
      store.set_feed_category(feed_id, cat_id)
    end

    app.async "feeds.categories" do
      store.list_categories
    end
  end

  def ensure_category(store : FluxReader::Store, name : String) : Int64
    store.ensure_category(name)
  end
end
