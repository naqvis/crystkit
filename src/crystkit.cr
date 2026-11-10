require "json"
require "webview"

# CrystKit is a native desktop application framework for Crystal.
#
# It pairs a native OS window — WebKit on macOS, WebKitGTK on Linux, WebView2
# on Windows — with a Crystal backend and an HTML/JS frontend, giving you a
# native desktop shell without giving up the productivity of web technologies
# for the interface.
#
# ## Architecture
#
# The framework is built around one object: `CrystKit::App`. It is the
# composition root for the entire desktop runtime and owns:
#
# * **Typed IPC** — Crystal command signatures define the payload shape
#   JavaScript must send. The frontend calls Crystal through an injected bridge
#   (`window.__CRYSTKIT_IPC__`); responses and failures cross the boundary in
#   predictable envelopes. See `IPC::Router`, `IPC::Channel`, `IPC::Context`.
# * **Capability security** — Native operations require explicit capabilities
#   and may be restricted by resource scopes and per-window grants. A
#   `capabilities.json` manifest declares app-owned authority. See
#   `Security::Context`, `Security::CapabilitySystem`, `Security::ScopeManager`.
# * **Native plugins** — Built-in and custom plugins expose native features
#   (file access, dialogs, tray, notifications, shell, system info, and many
#   more) through the same command, metadata, lifecycle, and policy model. See
#   `Plugin::Base`, `Plugin::Context`, `Plugin::Registry`, `Plugins::*`.
# * **Multi-window lifecycle** — Windows are runtime-owned, registered,
#   wired to IPC, and cleaned up by the app. See `Core::Window`,
#   `Core::WindowRegistry`, `WindowOptions`.
# * **Platform services** — A single `Platform::Services` facade composes all
#   native backends (window, dialog, tray, menu, clipboard, notifications,
#   shortcuts, printing, and more) with compile-time platform selection. See
#   `Platform::Services`.
# * **Builder workflow** — The `crystkit` CLI scaffolds projects, serves
#   frontend assets, builds Crystal binaries, bundles apps per platform, and
#   generates type schemas. See the `Build` and `CLI` modules.
module CrystKit
  include ::Webview

  # Semantic version of the shard.
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}
end

require "./platform"
require "./core/native_window"
require "./core/main_thread"
require "./core/fibers"
require "./core/future"
require "./state/registry"
require "./app/app"
require "./plugins"
require "./test/fake_frontend"
require "./ext/buffered"
