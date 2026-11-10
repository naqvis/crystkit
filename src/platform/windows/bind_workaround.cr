{% if flag?(:win32) %}
  # Windows: single C++ bind dispatcher + user-script injection via `init`.
  #
  # The vendor C++ `bind` deadlocks on the 2nd+ call because
  # `replace_user_script` -> `add_user_script_impl` pumps the event loop
  # from within a WndProc (WebView2's `AddScriptToExecuteOnDocumentCreated`
  # is async). We call C++ `bind` exactly once -- a routing dispatcher -- and
  # define all JS globals as user scripts so they survive page loads.
  module CrystKit::WindowsBindWorkaround
    @bind_accumulator = {} of String => JSProc
    @cxx_dispatcher_registered = false
    @page_has_navigated = false

    def bind(name : String, fn : JSProc)
      @bind_accumulator[name] = fn
      unless @cxx_dispatcher_registered
        @cxx_dispatcher_registered = true
        super("__crystal_dispatch", ->(args : Array(JSON::Any)) : JSON::Any {
          n = args[0]?.try(&.as_s)
          return JSON::Any.new(nil) unless n
          rest = args[1..]? || [] of JSON::Any
          @bind_accumulator[n]?.try(&.call(rest)) || JSON::Any.new(nil)
        })
      end
      if @page_has_navigated
        eval("window[#{name.to_json}]=function(...a){return window.__crystal_dispatch(#{name.to_json},...a)}")
      end
    end

    def unbind(name : String)
      @bind_accumulator.delete(name)
      if @page_has_navigated
        eval("delete window[#{name.to_json}]")
      end
    end

    def html=(html : String)
      inject_all_binding_globals
      @page_has_navigated = true
      super
    end

    def navigate(url)
      inject_all_binding_globals
      @page_has_navigated = true
      super
    end

    private def inject_all_binding_globals
      return if @bind_accumulator.empty?
      globals = @bind_accumulator.keys.sort.map { |n|
        "window[#{n.to_json}]=function(...a){return window.__crystal_dispatch(#{n.to_json},...a)}"
      }.join(";")
      init("(function(){#{globals}})()")
    end
  end
{% end %}
