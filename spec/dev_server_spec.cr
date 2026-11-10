require "./spec_helper"
require "../src/features/dev_server"

describe CrystKit::Features::DevServer do
  describe "MIME types" do
    it "returns text/html for .html" do
      _server = CrystKit::Features::DevServer.new("./tmp")
      mime = CrystKit::Features::DevServer::MIME_TYPES
      mime[".html"].should eq("text/html")
      mime[".css"].should eq("text/css")
      mime[".js"].should eq("application/javascript")
      mime[".png"].should eq("image/png")
      mime[".json"].should eq("application/json")
    end
    it "returns octet-stream for unknown extensions" do
      mime = CrystKit::Features::DevServer::MIME_TYPES
      mime[".xyz"]?.should be_nil
    end
  end
  describe "live reload JS" do
    it "contains WebSocket URL construction" do
      js = CrystKit::Features::DevServer::LIVE_RELOAD_JS
      js.should contain("__crystal_ws")
      js.should contain("WebSocket")
      js.should contain("reload")
      js.should contain("startPolling")
    end
    it "contains the polling fallback endpoint" do
      js = CrystKit::Features::DevServer::LIVE_RELOAD_JS
      js.should contain("__crystal_ping")
    end
  end
end
