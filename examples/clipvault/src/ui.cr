require "log"

module ClipVault::UI
  Log = ::Log.for(self)

  @@panel : CrystKit::Core::Window? = nil

  def self.setup(app, panel)
    @@panel = panel

    app.on("panel:hide") do |_payload|
      panel.hide
    end

    app.on("panel:toggle") do |_payload|
      toggle_panel(panel)
    end

    app.on("clipvault:quit") do |_payload|
      panel.terminate
    end

    setup_tray(app, panel)
    setup_menu(app, panel)
  end

  private def self.setup_tray(app, panel)
    icon = Path[__DIR__] / ".." / "assets" / "tray_icon.png"

    app.tray do |tray|
      tray.menu do |menu|
        menu.add_item("toggle", "Toggle Panel", accelerator: "Cmd+Shift+V") { |_| toggle_panel(panel) }
        menu.add_item("paste", "Paste last item") { |_| app.emit("clipboard:paste_last", nil) }
        menu.add_separator
        menu.add_item("settings", "Preferences") { |_| show_panel_and_settings(panel, app) }
        menu.add_separator
        menu.add_item("clear", "Clear History") { |_| show_panel_and_emit(panel, app, "menu:clear") }
        menu.add_item("export", "Export Data") { |_| show_panel_and_emit(panel, app, "menu:export") }
        menu.add_item("import", "Import Data") { |_| show_panel_and_emit(panel, app, "menu:import") }
        menu.add_separator
        menu.add_item("toggle_dark", "Toggle Dark Mode") { |_| show_panel_and_emit(panel, app, "menu:toggle_dark") }
        menu.add_item("devtools", "Toggle DevTools") { |_| show_panel_and_emit(panel, app, "menu:devtools") }
        menu.add_separator
        menu.add_item("quit", "Quit") { |_| panel.terminate }
      end
      tray.create(icon, "ClipVault")
      tray.on_click { |btn| toggle_panel(panel) if btn.left? }
    end
  rescue ex
    Log.warn { "tray unavailable: #{ex.message}" }
  end

  private def self.setup_menu(app, panel)
    app.menu_bar(target: panel) do |menu_bar|
      app_menu = CrystKit::Features::Menu.new("ClipVault")
      app_menu.add_item("Toggle Panel", "Cmd+Shift+V") { toggle_panel(panel) }
      app_menu.add_separator
      app_menu.add_item("Preferences", "Cmd+,") { app.emit("menu:settings", nil) }
      app_menu.add_separator
      app_menu.add_item("Quit", "Cmd+Q") { panel.terminate }
      menu_bar.add(app_menu)

      edit_menu = CrystKit::Features::Menu.new("Edit")
      edit_menu.add_item("Clear History", nil) { app.emit("menu:clear", nil) }
      edit_menu.add_item("Export Data", nil) { app.emit("menu:export", nil) }
      edit_menu.add_item("Import Data", nil) { app.emit("menu:import", nil) }
      menu_bar.add(edit_menu)

      view_menu = CrystKit::Features::Menu.new("View")
      view_menu.add_item("Toggle Dark Mode", "Cmd+D") { app.emit("menu:toggle_dark", nil) }
      view_menu.add_separator
      view_menu.add_item("Toggle DevTools", "Cmd+Alt+I") { app.emit("menu:devtools", nil) }
      menu_bar.add(view_menu)
    end
  rescue ex
    Log.warn { "menu bar unavailable: #{ex.message}" }
  end

  private def self.toggle_panel(panel)
    if panel.visible?
      panel.hide
    else
      panel.show_at_cursor
    end
  end

  private def self.show_panel_and_settings(panel, app)
    panel.show_at_cursor unless panel.visible?
    app.emit("menu:settings", nil)
  end

  private def self.show_panel_and_emit(panel, app, event)
    panel.show_at_cursor unless panel.visible?
    app.emit(event, nil)
  end
end
