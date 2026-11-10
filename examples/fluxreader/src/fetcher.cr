require "./parser"

module FluxReader::Fetcher
  extend self

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "feeds.refresh", Int64 do |feed_id, _cancel|
      feed = store.find_feed(feed_id)
      next false unless feed
      refresh_one(app, store, feed.id, feed.url, feed.last_etag)
      true
    end

    app.command "feeds.refresh_all" do
      spawn { refresh_all(app, store) }
      true
    end

    spawn(name: "fluxreader-refresh-loop") do
      loop do
        sleep 60.seconds
        break if !app.running? || store.closed?
        refresh_all(app, store)
      end
    end
  end

  def refresh_all(app : CrystKit::App, store : FluxReader::Store)
    return unless app.running?
    return if store.closed?

    store.all_feeds.each do |feed|
      refresh_one(app, store, feed.id, feed.url, feed.last_etag)
      Fiber.yield
    end
  end

  def refresh_one(app : CrystKit::App, store : FluxReader::Store, feed_id : Int64, url : String, etag : String?)
    return if store.closed?

    unless url.starts_with?("http://") || url.starts_with?("https://")
      Log.warn { "fluxreader: skipping feed with missing scheme: #{url}" }
      return
    end

    begin
      http = app.find_plugin(CrystKit::Plugins::HTTP).client
      headers = {"User-Agent" => "FluxReader/1.0"}
      headers["If-None-Match"] = etag if etag

      response = http.get(url, CrystKit::Features::RequestOptions.new(headers: headers))
      return if response.status == 304

      unless response.status >= 200 && response.status < 300
        Log.warn { "fluxreader: feed not available (#{response.status}): #{url}" }
        store.increment_feed_error(feed_id, Time.utc.to_rfc3339)
        return
      end

      new_etag = response.headers["ETag"]?
      feed = FeedParser.parse(response.text)
      return unless feed

      now = Time.utc.to_rfc3339
      store.update_feed_after_fetch(feed_id, feed.title, feed.site_url, feed.description, now, new_etag)

      new_count = 0
      feed.articles.each do |article|
        existing = store.find_article(feed_id, article.guid)
        next if existing

        store.add_article(feed_id, article, now)
        new_count += 1
      end

      feed_title = store.feed_title(feed_id) || url
      app.emit("feed:updated", {"id" => feed_id, "title" => feed_title})
      if new_count > 0
        Notifications.show(app, feed_title, "#{new_count} new article(s)")
      end
    rescue ex
      msg = "#{ex.class.name}: #{ex.message}"
      Log.error { "fluxreader: feed refresh failed for #{url}: #{msg}" }
      begin
        store.increment_feed_error(feed_id, Time.utc.to_rfc3339)
      rescue
      end
      app.emit("feed:error", {"feed_id" => feed_id, "message" => msg})
    end
  end
end
