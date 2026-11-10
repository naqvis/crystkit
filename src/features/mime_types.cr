require "mime"

module CrystKit
  module Features
    module MimeTypes
      TABLE = {
        ".html"  => "text/html",
        ".css"   => "text/css",
        ".js"    => "application/javascript",
        ".json"  => "application/json",
        ".png"   => "image/png",
        ".jpg"   => "image/jpeg",
        ".jpeg"  => "image/jpeg",
        ".gif"   => "image/gif",
        ".svg"   => "image/svg+xml",
        ".ico"   => "image/x-icon",
        ".woff"  => "font/woff",
        ".woff2" => "font/woff2",
        ".ttf"   => "font/ttf",
        ".txt"   => "text/plain",
        ".xml"   => "application/xml",
        ".pdf"   => "application/pdf",
        ".map"   => "application/json",
      }

      def self.for_extension(ext : String, fallback : String = "application/octet-stream") : String
        TABLE[ext]? || fallback
      end
    end
  end
end
