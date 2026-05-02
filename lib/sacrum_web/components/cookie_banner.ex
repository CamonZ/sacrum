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
            We use cookies to enhance your experience. Choose whether to allow non-essential cookies.
          </p>
          <div class="flex gap-2 flex-shrink-0">
            <button
              id="cookie-reject"
              type="button"
              class="px-3 sm:px-4 py-2 rounded-lg bg-surface border border-border text-text-primary text-sm font-medium hover:bg-border transition-colors"
            >
              Reject
            </button>
            <button
              id="cookie-accept"
              type="button"
              class="px-3 sm:px-4 py-2 rounded-lg bg-accent text-accent-fg text-sm font-medium hover:bg-accent-hover transition-colors"
            >
              Accept
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
