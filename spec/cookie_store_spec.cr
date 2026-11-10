require "http/headers"
require "./spec_helper"
require "../src/features/cookie_store"
require "../src/features/minimize_to_tray"

def new_cookie_store
  dir = File.tempname("cookie_test")
  Dir.mkdir_p(dir)
  CrystKit::Features::CookieStore.new(Path[dir])
end

describe CrystKit::Features::Cookie do
  it "serializes to JSON" do
    c = CrystKit::Features::Cookie.new(name: "n", value: "v", domain: "d.com")
    json = c.to_json
    json.should contain("n")
    json.should contain("d.com")
  end

  it "deserializes from JSON" do
    json = %({"name":"n","value":"v","domain":"d.com","path":"/","secure":false,"http_only":false,"same_site":"Lax"})
    c = CrystKit::Features::Cookie.from_json(json)
    c.name.should eq("n")
    c.domain.should eq("d.com")
  end
end

describe CrystKit::Features::CookieStore do
  it "stores and retrieves cookies" do
    store = new_cookie_store
    cookie = CrystKit::Features::Cookie.new(name: "session", value: "abc123", domain: "example.com")
    store.set(cookie)

    uri = URI.parse("https://example.com/page")
    cookies = store.get(uri)
    cookies.size.should eq(1)
    cookies.first.value.should eq("abc123")
  end

  it "returns empty for unknown host" do
    store = new_cookie_store
    uri = URI.parse("https://unknown.com")
    store.get(uri).should be_empty
  end

  it "replaces cookie with same name and path" do
    store = new_cookie_store
    store.set(CrystKit::Features::Cookie.new(name: "x", value: "old", domain: "ex.com"))
    store.set(CrystKit::Features::Cookie.new(name: "x", value: "new", domain: "ex.com"))

    uri = URI.parse("https://ex.com")
    cookies = store.get(uri)
    cookies.size.should eq(1)
    cookies.first.value.should eq("new")
  end

  it "deletes a cookie" do
    store = new_cookie_store
    store.set(CrystKit::Features::Cookie.new(name: "del", value: "me", domain: "ex.com"))
    store.delete("del", "ex.com")

    uri = URI.parse("https://ex.com")
    store.get(uri).should be_empty
  end

  it "clears all cookies" do
    store = new_cookie_store
    store.set(CrystKit::Features::Cookie.new(name: "a", value: "1", domain: "a.com"))
    store.set(CrystKit::Features::Cookie.new(name: "b", value: "2", domain: "b.com"))
    store.clear
    store.get(URI.parse("https://a.com")).should be_empty
    store.get(URI.parse("https://b.com")).should be_empty
  end

  it "persists to disk" do
    SpecHelpers.with_temp_dir do |dir|
      storage = Path[dir] / "cookies"
      store = CrystKit::Features::CookieStore.new(storage)
      store.set(CrystKit::Features::Cookie.new(name: "persist", value: "yes", domain: "ex.com"))

      store2 = CrystKit::Features::CookieStore.new(storage)
      uri = URI.parse("https://ex.com")
      cookies = store2.get(uri)
      cookies.size.should eq(1)
      cookies.first.value.should eq("yes")
    end
  end

  it "ingests Set-Cookie headers" do
    store = new_cookie_store
    uri = URI.parse("https://ex.com")
    headers = HTTP::Headers.new
    headers.add("Set-Cookie", "token=xyz; Path=/; Domain=ex.com")

    store.ingest_headers(uri, headers)
    cookies = store.get(uri)
    cookies.size.should eq(1)
    cookies.first.name.should eq("token")
    cookies.first.value.should eq("xyz")
  end

  it "applies cookies to request headers" do
    store = new_cookie_store
    store.set(CrystKit::Features::Cookie.new(name: "sid", value: "abc", domain: "ex.com"))

    uri = URI.parse("https://ex.com/path")
    headers = HTTP::Headers.new
    result = store.apply(uri, headers)

    result["Cookie"]?.should eq("sid=abc")
  end

  it "excludes expired cookies" do
    store = new_cookie_store
    past = Time.utc - 3600.seconds
    store.set(CrystKit::Features::Cookie.new(name: "exp", value: "gone", domain: "ex.com", expires: past))

    uri = URI.parse("https://ex.com")
    store.get(uri).should be_empty
  end

  it "ingests multiple Set-Cookie headers" do
    store = new_cookie_store
    uri = URI.parse("https://ex.com")
    headers = HTTP::Headers.new
    headers.add("Set-Cookie", "a=1; Path=/")
    headers.add("Set-Cookie", "b=2; Path=/")

    store.ingest_headers(uri, headers)
    cookies = store.get(uri)
    cookies.size.should eq(2)
  end

  it "is thread-safe" do
    store = new_cookie_store
    channels = [] of Channel(Nil)
    10.times do |i|
      ch = Channel(Nil).new
      channels << ch
      spawn do
        store.set(CrystKit::Features::Cookie.new(name: "t#{i}", value: "#{i}", domain: "ex.com"))
        ch.send(nil)
      end
    end
    channels.each(&.receive)

    uri = URI.parse("https://ex.com")
    store.get(uri).size.should eq(10)
  end
end

describe CrystKit::Features::MinimizeToTray do
  it "enables without capabilities" do
    m = CrystKit::Features::MinimizeToTray.new
    m.enable
    m.enabled?.should be_true
  end

  it "disables" do
    m = CrystKit::Features::MinimizeToTray.new
    m.enable
    m.disable
    m.enabled?.should be_false
  end

  it "trigger_minimize returns true when enabled" do
    m = CrystKit::Features::MinimizeToTray.new
    m.enable
    m.trigger_minimize.should be_true
  end

  it "trigger_minimize returns false when disabled" do
    m = CrystKit::Features::MinimizeToTray.new
    m.trigger_minimize.should be_false
  end

  it "registers minimize handler" do
    m = CrystKit::Features::MinimizeToTray.new
    called = false
    m.on_minimize { called = true }
    m.enable
    m.trigger_minimize
    called.should be_true
  end
end
