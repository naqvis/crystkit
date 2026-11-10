module FluxReader::DeepLinks
  extend self

  def setup(app : CrystKit::App, url : String?)
    app.on("deeplink:subscribe") do |payload|
      if feed_url = payload["url"]?.try(&.as_s?)
        app.emit("ui:show_subscribe", {"url" => feed_url})
      end
    end

    if url && url.starts_with?("fluxreader://")
      uri = URI.parse(url)
      if uri.host == "subscribe" && (feed_url = uri.query_params["url"]?)
        app.emit("ui:show_subscribe", {"url" => feed_url})
      end
    end
  end
end
