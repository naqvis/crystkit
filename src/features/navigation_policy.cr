module CrystKit::Features
  # Controls which URLs the webview is allowed to navigate to.
  #
  # The webview integration calls `#evaluate` with each candidate URL before
  # committing the navigation, and the registered handler decides whether to
  # allow, deny, or hand the URL off to the system browser. When no handler
  # is registered the policy defaults to *allow*.
  #
  # Usage:
  # ```
  # policy = NavigationPolicy.new
  # policy.on_navigation do |url|
  #   url.starts_with?("https://example.com") ? Decision::Allow : Decision::Deny
  # end
  # ```
  class NavigationPolicy
    Log = ::Log.for(self)

    # The verdict returned by a navigation handler for a single URL.
    #
    # `Allow` lets the webview commit the navigation; `Deny` cancels it
    # silently; `External` rejects it and opens the URL in the user's default
    # browser.
    enum Decision
      # Navigation is permitted in the webview.
      Allow
      # Navigation is blocked; the webview stays on its current page.
      Deny
      # Navigation should be opened in the system default browser
      # instead of the webview.
      External
    end

    @handler : Proc(String, Decision)?

    # Register a callback that decides whether navigation to a URL is allowed.
    #
    # Only one handler is active at a time; re-registering replaces the
    # previous handler. The block receives the raw URL string (with
    # query and fragment) and must return a `Decision`.
    def on_navigation(&block : String -> Decision)
      @handler = block
    end

    # Evaluate a URL against the registered handler.
    #
    # Returns `Decision::Allow` if no handler is set (the policy fails open).
    # Otherwise the handler runs synchronously and its return value is
    # passed through verbatim — the policy itself never overrides the
    # handler's decision.
    def evaluate(url : String) : Decision
      if handler = @handler
        handler.call(url)
      else
        Decision::Allow
      end
    end

    # Remove the navigation handler; all navigation will be allowed.
    #
    # Idempotent. After `#clear` returns, `#evaluate` short-circuits to
    # `Decision::Allow` for every URL.
    def clear
      @handler = nil
    end
  end
end
