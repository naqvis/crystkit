require "xml"
require "./fetcher"

module FluxReader::OPML
  extend self

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "opml.import", String do |path, _cancel|
      xml = File.read(path)
      doc = XML.parse(xml)
      body = doc.xpath_node("/opml/body")
      next {"added" => 0} unless body

      imported = 0
      parse_outlines(body).each do |title, url, category|
        next if url.blank?
        cat_id = Feeds.ensure_category(store, category.presence || "Feed")
        existing = store.find_feed_by_url(url)
        next if existing
        feed_title = title.presence || url
        store.add_feed(feed_title, url, cat_id)
        imported += 1
      end

      if imported > 0
        spawn { FluxReader::Fetcher.refresh_all(app, store) }
      end

      {"added" => imported}
    end

    app.async "opml.export", String do |path, _cancel|
      feeds = store.feeds_with_category
      xml = generate(feeds)
      File.write(path, xml)
      true
    end
  end

  private def parse_outlines(node : XML::Node, category : String = "Feed") : Array({String, String, String})
    results = [] of {String, String, String}
    node.xpath_nodes("outline").each do |outline|
      if xml_url = outline["xmlUrl"]?
        title = outline["title"]? || outline["text"]? || xml_url
        results << {title, xml_url, category}
      elsif folder_title = outline["title"]? || outline["text"]?
        results.concat(parse_outlines(outline, folder_title))
      else
        results.concat(parse_outlines(outline, category))
      end
    end
    results
  end

  private def generate(feeds : Array(FluxReader::Row)) : String
    String.build do |io|
      io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
      io << %(<opml version="2.0">\n)
      io << "  <head><title>FluxReader Subscriptions</title></head>\n"
      io << "  <body>\n"

      by_category = feeds.group_by { |f| f["category"].as(String) }
      by_category.each do |cat, cat_feeds|
        io << %(    <outline text="#{escape_xml(cat)}" title="#{escape_xml(cat)}">\n)
        cat_feeds.each do |f|
          title = f["title"].as(String)
          url = f["url"].as(String)
          io << %(      <outline type="rss" text="#{escape_xml(title)}" title="#{escape_xml(title)}" xmlUrl="#{escape_xml(url)}"/>\n)
        end
        io << "    </outline>\n"
      end

      io << "  </body>\n"
      io << "</opml>\n"
    end
  end

  private def escape_xml(str : String) : String
    str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub("\"", "&quot;").gsub("'", "&apos;")
  end
end
