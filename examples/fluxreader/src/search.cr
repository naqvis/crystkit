module FluxReader::Search
  extend self

  record SearchQuery, q : String = "", limit : Int64 = 50_i64, offset : Int64 = 0_i64 do
    include JSON::Serializable
  end

  def setup(app : CrystKit::App, store : FluxReader::Store)
    app.async "search.query", SearchQuery do |sq, _cancel|
      next [] of FluxReader::Row if sq.q.blank?
      store.search(sq.q, sq.limit, sq.offset)
    end
  end
end
