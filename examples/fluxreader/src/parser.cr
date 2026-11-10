require "xml"
require "time"

module FluxReader::FeedParser
  struct Article
    getter guid : String
    getter title : String
    getter link : String?
    getter author : String?
    getter summary : String?
    getter content : String?
    getter published_at : String?

    def initialize(@guid, @title, @link, @author, @summary, @content, @published_at)
    end
  end

  struct Feed
    getter title : String
    getter site_url : String?
    getter description : String?
    getter articles : Array(Article)

    def initialize(@title, @site_url, @description, @articles)
    end
  end

  def self.parse(xml : String) : Feed?
    doc = XML.parse(xml)
    root = doc.root
    return nil unless root

    case root.name
    when "rss"  then parse_rss(root)
    when "feed" then parse_atom(root)
    else             nil
    end
  rescue XML::Error
    nil
  end

  private def self.parse_rss(root : XML::Node) : Feed?
    channel = root.xpath_node("channel")
    return nil unless channel

    title = text(channel, "title") || "Untitled"
    link = text(channel, "link")
    description = text(channel, "description")

    ns = {"content" => "http://purl.org/rss/1.0/modules/content/", "dc" => "http://purl.org/dc/elements/1.1/"}

    articles = root.xpath_nodes("channel/item").compact_map do |item|
      guid = text(item, "guid") || text(item, "link")
      next unless guid
      Article.new(
        guid: guid,
        title: text(item, "title") || "Untitled",
        link: text(item, "link"),
        author: text(item, "author") || text(item, "dc:creator", ns),
        summary: text(item, "description"),
        content: text(item, "content:encoded", ns),
        published_at: normalize_date(text(item, "pubDate")),
      )
    end

    Feed.new(title: title, site_url: link, description: description, articles: articles)
  end

  private def self.parse_atom(root : XML::Node) : Feed?
    ns = {"atom" => "http://www.w3.org/2005/Atom"}
    title = text(root, "atom:title", ns) || text(root, "title") || "Untitled"
    link = root.xpath_node("atom:link[@rel='alternate']", namespaces: ns).try(&.[]("href")) || root.xpath_node("link").try(&.[]("href"))
    description = text(root, "atom:subtitle", ns) || text(root, "subtitle")

    articles = root.xpath_nodes("atom:entry", namespaces: ns).compact_map do |entry|
      id = text(entry, "atom:id", ns) || text(entry, "id")
      next unless id
      updated = text(entry, "atom:updated", ns) || text(entry, "updated")
      published = text(entry, "atom:published", ns) || text(entry, "published")
      Article.new(
        guid: id,
        title: text(entry, "atom:title", ns) || text(entry, "title") || "Untitled",
        link: entry.xpath_node("atom:link[@rel='alternate']", namespaces: ns).try(&.[]("href")) || entry.xpath_node("link").try(&.[]("href")),
        author: text(entry, "atom:author/atom:name", ns) || text(entry, "author/name"),
        summary: text(entry, "atom:summary", ns) || text(entry, "summary"),
        content: text(entry, "atom:content", ns) || text(entry, "content"),
        published_at: normalize_date(published || updated),
      )
    end

    Feed.new(title: title, site_url: link, description: description, articles: articles)
  end

  private def self.text(node : XML::Node, expr : String, ns : Hash(String, String)? = nil) : String?
    node.xpath_node(expr, namespaces: ns).try(&.text)
  rescue XML::Error
    nil
  end

  private def self.normalize_date(value : String?) : String?
    return nil unless value
    formats = [
      Time::Format.new("%a, %d %b %Y %H:%M:%S %z"),
      Time::Format.new("%Y-%m-%dT%H:%M:%S%z"),
      Time::Format.new("%Y-%m-%dT%H:%M:%SZ"),
      Time::Format.new("%Y-%m-%dT%H:%M:%S.%3N%z"),
      Time::Format.new("%Y-%m-%dT%H:%M:%S.%3NZ"),
    ]
    formats.each do |fmt|
      begin
        return fmt.parse(value).to_rfc3339
      rescue
      end
    end
    nil
  end
end
