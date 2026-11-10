module FluxReader
  # Row value union used by all in-memory row hashes returned to the frontend.
  alias RowValue = Int64 | String | Nil
  alias Row = Hash(String, RowValue)

  # In-memory RSS reader store (categories, feeds, articles).
  # In-memory only: data resets on restart.
  class Store
    struct Category
      property id : Int64
      property name : String
      property sort_order : Int64

      def initialize(@id : Int64, @name : String, @sort_order : Int64 = 0_i64)
      end

      def to_hash : Row
        h = {} of String => RowValue
        h["id"] = id
        h["name"] = name
        h["sort_order"] = sort_order
        h
      end
    end

    struct Feed
      property id : Int64
      property title : String
      property url : String
      property site_url : String?
      property description : String?
      property category_id : Int64?
      property update_interval_minutes : Int64
      property last_fetched_at : String?
      property last_etag : String?
      property error_count : Int64
      property created_at : String
      property updated_at : String

      def initialize(@id : Int64, @title : String, @url : String, @site_url : String? = nil,
                     @description : String? = nil, @category_id : Int64? = nil,
                     @update_interval_minutes : Int64 = 60_i64, @last_fetched_at : String? = nil,
                     @last_etag : String? = nil, @error_count : Int64 = 0_i64,
                     @created_at : String = "", @updated_at : String = "")
      end

      def to_hash : Row
        h = {} of String => RowValue
        h["id"] = id
        h["title"] = title
        h["url"] = url
        h["site_url"] = site_url
        h["description"] = description
        h["category_id"] = category_id
        h["update_interval_minutes"] = update_interval_minutes
        h["last_fetched_at"] = last_fetched_at
        h["last_etag"] = last_etag
        h["error_count"] = error_count
        h["created_at"] = created_at
        h["updated_at"] = updated_at
        h
      end
    end

    struct Article
      property id : Int64
      property feed_id : Int64
      property guid : String
      property title : String
      property link : String?
      property author : String?
      property summary : String?
      property content : String?
      property published_at : String?
      property fetched_at : String
      property is_read : Int64
      property is_favorite : Int64

      def initialize(@id : Int64, @feed_id : Int64, @guid : String, @title : String,
                     @link : String? = nil, @author : String? = nil, @summary : String? = nil,
                     @content : String? = nil, @published_at : String? = nil,
                     @fetched_at : String = "", @is_read : Int64 = 0_i64,
                     @is_favorite : Int64 = 0_i64)
      end

      def to_hash : Row
        h = {} of String => RowValue
        h["id"] = id
        h["feed_id"] = feed_id
        h["title"] = title
        h["link"] = link
        h["author"] = author
        h["summary"] = summary
        h["content"] = content
        h["published_at"] = published_at
        h["fetched_at"] = fetched_at
        h["is_read"] = is_read
        h["is_favorite"] = is_favorite
        h
      end
    end

    @categories = [] of Category
    @feeds = [] of Feed
    @articles = [] of Article
    @next_category_id = 1_i64
    @next_feed_id = 1_i64
    @next_article_id = 1_i64

    def self.open(storage_dir : Path) : Store
      new
    end

    def initialize
    end

    def close : Nil
    end

    def closed? : Bool
      false
    end

    private def now : String
      Time.utc.to_rfc3339
    end

    private def category_name(id : Int64?) : String?
      return nil unless id
      @categories.find { |c| c.id == id }.try(&.name)
    end

    # ── Categories ──

    def ensure_category(name : String) : Int64
      if cat = @categories.find { |c| c.name == name }
        return cat.id
      end
      cat = Category.new(@next_category_id, name)
      @next_category_id += 1
      @categories << cat
      cat.id
    end

    def list_categories : Array(Row)
      @categories.sort { |a, b|
        c = a.sort_order <=> b.sort_order
        c == 0 ? (a.name <=> b.name) : c
      }.map(&.to_hash)
    end

    # ── Feeds ──

    def list_feeds : Array(Row)
      @feeds.sort_by(&.title).map do |f|
        unread = @articles.count { |a| a.feed_id == f.id && a.is_read == 0 }
        h = f.to_hash
        h["category"] = category_name(f.category_id)
        h["unread"] = unread.to_i64
        h
      end
    end

    def all_feeds : Array(Feed)
      @feeds.sort_by(&.id)
    end

    def find_feed(id : Int64) : Feed?
      @feeds.find { |f| f.id == id }
    end

    def find_feed_by_url(url : String) : Feed?
      @feeds.find { |f| f.url == url }
    end

    def feed_title(id : Int64) : String?
      @feeds.find { |f| f.id == id }.try(&.title)
    end

    def add_feed(title : String, url : String, category_id : Int64) : Row
      feed = Feed.new(
        id: @next_feed_id,
        title: title,
        url: url,
        category_id: category_id,
        created_at: now,
        updated_at: now,
      )
      @next_feed_id += 1
      @feeds << feed
      feed.to_hash
    end

    def remove_feed(id : Int64) : Nil
      @articles.reject! { |a| a.feed_id == id }
      @feeds.reject! { |f| f.id == id }
    end

    def set_feed_category(feed_id : Int64, category_id : Int64) : Row?
      feed = @feeds.find { |f| f.id == feed_id }
      return nil unless feed
      feed.category_id = category_id
      feed.updated_at = now
      h = feed.to_hash
      h["category"] = category_name(feed.category_id)
      h
    end

    def increment_feed_error(id : Int64, at : String) : Nil
      if feed = @feeds.find { |f| f.id == id }
        feed.error_count += 1
        feed.updated_at = at
      end
    end

    def update_feed_after_fetch(id : Int64, title : String, site_url : String?, description : String?,
                                fetched_at : String, etag : String?) : Nil
      if feed = @feeds.find { |f| f.id == id }
        feed.title = title
        feed.site_url = site_url
        feed.description = description
        feed.last_fetched_at = fetched_at
        feed.last_etag = etag
        feed.error_count = 0
        feed.updated_at = fetched_at
      end
    end

    # OPML export rows: title, url, category (defaults to "Feed").
    def feeds_with_category : Array(Row)
      @feeds.sort_by(&.title).map do |f|
        h = f.to_hash
        h["category"] = category_name(f.category_id) || "Feed"
        h
      end
    end

    # ── Articles ──

    def list_articles(filter : String, feed_id : Int64?, category_id : Int64?,
                      limit : Int64, offset : Int64) : Array(Row)
      feed_ids = if feed_id
                   [feed_id]
                 elsif category_id
                   @feeds.select { |f| f.category_id == category_id }.map(&.id)
                 end

      matching = @articles.select do |a|
        ok = true
        if ids = feed_ids
          ok = ids.includes?(a.feed_id)
        end
        ok && case filter
        when "unread"    then a.is_read == 0
        when "favorites" then a.is_favorite == 1
        else                  true
        end
      end

      matching.sort { |a, b| (b.published_at || "") <=> (a.published_at || "") }
        .skip(offset)
        .first(limit)
        .map { |a| article_row(a) }
    end

    def get_article(id : Int64) : Row?
      @articles.find { |a| a.id == id }.try { |a| article_row(a) }
    end

    def find_article_by_id(id : Int64) : Article?
      @articles.find { |a| a.id == id }
    end

    def find_article(feed_id : Int64, guid : String) : Article?
      @articles.find { |a| a.feed_id == feed_id && a.guid == guid }
    end

    def add_article(feed_id : Int64, article : FeedParser::Article, fetched_at : String) : Nil
      @articles << Article.new(
        id: @next_article_id,
        feed_id: feed_id,
        guid: article.guid,
        title: article.title,
        link: article.link,
        author: article.author,
        summary: article.summary,
        content: article.content,
        published_at: article.published_at,
        fetched_at: fetched_at,
      )
      @next_article_id += 1
    end

    def set_article_content(id : Int64, content : String) : Nil
      if a = @articles.find { |a| a.id == id }
        a.content = content
      end
    end

    def mark_read(id : Int64) : Row?
      a = @articles.find { |a| a.id == id }
      return nil unless a
      a.is_read = 1_i64
      article_row(a)
    end

    def mark_unread(id : Int64) : Row?
      a = @articles.find { |a| a.id == id }
      return nil unless a
      a.is_read = 0_i64
      article_row(a)
    end

    def mark_all_read(feed_id : Int64?, category_id : Int64?) : Nil
      cat_feed_ids = category_id ? @feeds.select { |f| f.category_id == category_id }.map(&.id) : nil
      @articles.each do |a|
        if feed_id
          a.is_read = 1_i64 if a.feed_id == feed_id
        elsif cat_feed_ids
          a.is_read = 1_i64 if cat_feed_ids.includes?(a.feed_id)
        else
          a.is_read = 1_i64
        end
      end
    end

    def toggle_favorite(id : Int64) : Row?
      a = @articles.find { |a| a.id == id }
      return nil unless a
      a.is_favorite = a.is_favorite == 1 ? 0_i64 : 1_i64
      article_row(a)
    end

    def article_counts : Hash(String, Int64)
      total = @articles.size.to_i64
      unread = @articles.count { |a| a.is_read == 0 }.to_i64
      favorites = @articles.count { |a| a.is_favorite == 1 }.to_i64
      {"all" => total, "unread" => unread, "favorites" => favorites}
    end

    def search(q : String, limit : Int64, offset : Int64) : Array(Row)
      ql = q.downcase
      matching = @articles.select do |a|
        a.title.downcase.includes?(ql) ||
          (a.author || "").downcase.includes?(ql) ||
          (a.summary || "").downcase.includes?(ql) ||
          (a.content || "").downcase.includes?(ql)
      end
      matching.sort { |a, b| (b.published_at || "") <=> (a.published_at || "") }
        .skip(offset)
        .first(limit)
        .map { |a| article_row(a) }
    end

    def clear_all : Nil
      @categories.clear
      @feeds.clear
      @articles.clear
    end

    # ── Row helpers ──

    private def article_row(a : Article) : Row
      h = a.to_hash
      h["feed_title"] = feed_title(a.feed_id) || ""
      h
    end
  end
end
