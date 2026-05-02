defmodule SacrumWeb.CookieBanner do
  use SacrumWeb, :html

  @spec cookie_banner(map()) :: Phoenix.LiveView.Rendered.t()
  def cookie_banner(assigns) do
    ~H"""
    <div
      id="cookie-banner"
      phx-hook="CookieConsent"
      hidden
      class="fixed bottom-0 left-0 right-0 z-50 bg-surface border-t border-border"
      role="region"
      aria-label="Cookie consent"
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4 sm:py-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <p class="flex-1 text-xs sm:text-sm text-text-secondary leading-relaxed">
            This website utilizes cookies.
          </p>
          <button
            id="cookie-ok"
            type="button"
            class="px-3 sm:px-4 py-2 rounded-lg bg-accent text-accent-fg text-sm font-medium hover:bg-accent-hover transition-colors flex-shrink-0"
          >
            OK
          </button>
        </div>
      </div>
    </div>
    """
  end
end
