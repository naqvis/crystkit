module FluxReader::Notifications
  extend self

  def setup(app : CrystKit::App)
  end

  def show(app : CrystKit::App, title : String, body : String)
    n = CrystKit::Features::Notification.new(title, body)
    app.find_plugin(CrystKit::Plugins::Notifications).notifications.show(n)
  rescue ex
    Log.warn { "fluxreader: notification failed: #{ex.message}" }
  end
end
