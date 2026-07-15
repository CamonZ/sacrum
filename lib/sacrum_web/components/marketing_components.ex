defmodule SacrumWeb.MarketingComponents do
  @moduledoc "Reusable primitives for Vertebrae's public marketing surface."

  use Phoenix.Component

  import SacrumWeb.CoreComponents, only: [icon: 1]

  @doc "Renders the Vertebrae wordmark and its compact spine mark."
  attr :label, :string, default: "Vertebrae"
  attr :compact?, :boolean, default: false
  attr :class, :any, default: nil

  @spec brand_mark(map()) :: Phoenix.LiveView.Rendered.t()
  def brand_mark(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-3 text-text-primary",
      @compact? && "gap-2",
      @class
    ]}>
      <span
        class="flex size-8 shrink-0 items-center justify-center rounded-sm bg-accent text-accent-fg"
        aria-hidden="true"
      >
        <svg viewBox="0 0 24 24" class="size-5" fill="none" stroke="currentColor" stroke-width="1.5">
          <path stroke-linecap="round" d="M12 2v20" />
          <path
            stroke-linecap="round"
            d="M8.5 6.5c0-1.2 1.6-2.2 3.5-2.2s3.5 1 3.5 2.2-1.6 2.2-3.5 2.2-3.5-1-3.5-2.2Z"
          />
          <path
            stroke-linecap="round"
            d="M8.5 12c0-1.2 1.6-2.2 3.5-2.2s3.5 1 3.5 2.2-1.6 2.2-3.5 2.2-3.5-1-3.5-2.2Z"
          />
          <path
            stroke-linecap="round"
            d="M8.5 17.5c0-1.2 1.6-2.2 3.5-2.2s3.5 1 3.5 2.2-1.6 2.2-3.5 2.2-3.5-1-3.5-2.2Z"
          />
        </svg>
      </span>
      <span :if={!@compact?} class="font-medium tracking-tight">{@label}</span>
    </span>
    """
  end

  @doc "Renders a mono, copper section label."
  attr :label, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  @spec eyebrow(map()) :: Phoenix.LiveView.Rendered.t()
  def eyebrow(assigns) do
    ~H"""
    <p id={@id} class={["marketing-eyebrow", @class]} {@rest}>{@label}</p>
    """
  end

  @doc "Renders a public-facing action as either an anchor or button."
  attr :href, :string, default: nil
  attr :id, :string, default: nil
  attr :variant, :string, values: ~w(primary secondary), default: "primary"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(target rel download aria-label)
  slot :inner_block, required: true

  @spec marketing_button(map()) :: Phoenix.LiveView.Rendered.t()
  def marketing_button(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <a
      id={@id}
      href={@href}
      class={[button_class(@variant), "marketing-button", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  def marketing_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={[button_class(@variant), "marketing-button", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "Renders a compact capability block with a stable testable id."
  attr :id, :string, required: true
  attr :number, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :class, :any, default: nil

  @spec feature_block(map()) :: Phoenix.LiveView.Rendered.t()
  def feature_block(assigns) do
    ~H"""
    <article id={@id} class={["marketing-card marketing-surface rounded-md p-6 sm:p-7", @class]}>
      <p class="font-mono text-xs text-text-faint" aria-hidden="true">{@number}</p>
      <h3 class="mt-12 text-xl font-medium tracking-tight text-text-primary">{@title}</h3>
      <p class="mt-3 max-w-sm text-sm leading-7 text-text-secondary">{@description}</p>
    </article>
    """
  end

  @doc "Renders a link card for a canonical Vertebrae-family repository."
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :description, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, default: "Repository"

  @spec repository_card(map()) :: Phoenix.LiveView.Rendered.t()
  def repository_card(assigns) do
    ~H"""
    <a
      id={@id}
      href={@href}
      class="marketing-card marketing-surface-raised group block rounded-md p-6 sm:p-8"
      target="_blank"
      rel="noreferrer"
      aria-label={"Open #{@name} on GitHub"}
    >
      <div class="flex items-start justify-between gap-6">
        <div>
          <p class="marketing-eyebrow">{@label}</p>
          <h3 class="mt-4 text-2xl font-medium tracking-tight text-text-primary">{@name}</h3>
        </div>
        <span
          class="flex size-9 shrink-0 items-center justify-center rounded-full border border-border text-text-muted transition-colors group-hover:border-accent group-hover:text-accent"
          aria-hidden="true"
        >
          <.icon name="hero-arrow-up-right" class="size-4" />
        </span>
      </div>
      <p class="mt-8 max-w-md text-sm leading-7 text-text-secondary">{@description}</p>
      <p class="mt-8 font-mono text-xs text-text-muted group-hover:text-accent">
        github.com/CamonZ/{@name}
      </p>
    </a>
    """
  end

  @doc "Renders a small list of footer links."
  attr :links, :list, required: true
  attr :id, :string, default: "footer-links"

  @spec footer_links(map()) :: Phoenix.LiveView.Rendered.t()
  def footer_links(assigns) do
    ~H"""
    <nav id={@id} aria-label="Footer">
      <ul class="flex flex-wrap items-center gap-x-6 gap-y-3 text-xs text-text-muted">
        <li :for={link <- @links}>
          <a class="marketing-link" href={link.href} target={link[:target]} rel={link[:rel]}>
            {link.label}
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  defp button_class("primary") do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-md bg-accent px-5 py-2.5 text-sm font-medium text-accent-fg hover:bg-accent-hover"
  end

  defp button_class("secondary") do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-md border border-border-strong bg-transparent px-5 py-2.5 text-sm font-medium text-text-primary hover:border-accent hover:text-accent"
  end
end
