require "log"
require "../../shell"

module CrystKit::Builder::Bundle::MacOS
  # Wraps the macOS `codesign`, `notarytool`, and `stapler` tools for
  # signing, notarizing, and stapling an `.app` bundle.
  #
  # Ad-hoc signing (identity `"-"` or empty) skips the hardened
  # runtime; Developer ID signing enables it. Notarization requires
  # the `AC_USERNAME`, `AC_TEAM_ID`, and `AC_PASSWORD` environment
  # variables.
  class CodeSign
    # :nodoc:
    Log = ::Log.for(self)

    # The signing identity passed to `codesign --sign`.
    getter identity : String
    # Optional path to an entitlements.plist forwarded to `codesign`.
    getter entitlements_path : String?

    # Creates a signer for *identity* with optional *entitlements_path*.
    def initialize(@identity : String, @entitlements_path = nil)
    end

    # Signs *app_path* with `codesign`, returning `true` on success.
    #
    # Entitlements are applied when `entitlements_path` is set.
    def sign(app_path : String) : Bool
      # Ad-hoc signing ("-") does not support hardened runtime options.
      # Developer ID / distribution signing should enable hardened runtime.
      ad_hoc = identity == "-" || identity.empty?

      args = ["--force", "--verify", "--verbose"]
      unless ad_hoc
        args.concat(["--options", "runtime"])
      end
      if ent = entitlements_path
        args.concat(["--entitlements", ent])
      end
      args.concat(["--sign", identity, app_path])

      if Shell.exec("codesign", args)
        Log.info { "Signed #{app_path} with identity '#{identity}'#{ad_hoc ? " (ad-hoc)" : ""}" }
        true
      else
        Log.error { "Code signing failed" }
        false
      end
    end

    # Verifies the signature of *app_path* via `codesign --verify`.
    def verify(app_path : String) : Bool
      Shell.exec("codesign", ["--verify", "--verbose", app_path])
    end

    # Notarizes *app_path* with bundle identifier *bundle_id*.
    #
    # Requires `AC_USERNAME`, `AC_TEAM_ID`, and `AC_PASSWORD`
    # environment variables.
    def notarize(app_path : String, bundle_id : String) : Bool
      username = ENV["AC_USERNAME"]?
      team_id = ENV["AC_TEAM_ID"]?
      password = ENV["AC_PASSWORD"]?
      unless username && team_id && password
        Log.error { "Notarization skipped: AC_USERNAME, AC_TEAM_ID, and AC_PASSWORD env vars required" }
        return false
      end

      # NOTE: Credentials passed via argv are visible via `ps`. For
      # production, prefer `notarytool --keychain-profile` (stores
      # creds in Keychain).
      zip_path = "#{app_path}.zip"
      result = Shell.capture("ditto", "-c", "-k", "--keepParent", app_path, zip_path)

      unless result.success?
        Log.error { "Failed to create zip for notarization: #{result.output}" }
        return false
      end

      result = Shell.capture("xcrun", "notarytool", "submit", zip_path,
        "--apple-id", username,
        "--team-id", team_id,
        "--password", password,
        "--wait")

      File.delete(zip_path) if File.exists?(zip_path)

      if result.success?
        Log.info { "Notarization submitted for #{app_path}" }
      else
        Log.error { "Notarization failed: #{result.output}" }
      end
      result.success?
    end

    # Staples a notarization ticket to *app_path* via `xcrun stapler`.
    def staple(app_path : String) : Bool
      if Shell.exec("xcrun", ["stapler", "staple", app_path])
        Log.info { "Stapled notarization ticket to #{app_path}" }
        true
      else
        Log.warn { "Stapling failed (may not be needed)" }
        false
      end
    end
  end
end
