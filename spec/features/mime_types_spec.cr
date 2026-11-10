require "../spec_helper"
require "../../src/features/mime_types"

describe CrystKit::Features::MimeTypes do
  describe ".for_extension" do
    it "returns the MIME type for a known extension" do
      CrystKit::Features::MimeTypes.for_extension(".html").should eq("text/html")
      CrystKit::Features::MimeTypes.for_extension(".js").should eq("application/javascript")
      CrystKit::Features::MimeTypes.for_extension(".svg").should eq("image/svg+xml")
    end

    it "falls back to application/octet-stream for unknown extensions" do
      CrystKit::Features::MimeTypes.for_extension(".xyz").should eq("application/octet-stream")
      CrystKit::Features::MimeTypes.for_extension("").should eq("application/octet-stream")
    end

    it "falls back to a custom default when provided" do
      CrystKit::Features::MimeTypes.for_extension(".xyz", "text/plain").should eq("text/plain")
    end
  end
end
