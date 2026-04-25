defmodule SacrumWeb.DesignSystemLive do
  @moduledoc false
  use SacrumWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Articulated Design System")}
  end

  attr :name, :string, required: true
  attr :class, :string, required: true
  attr :hex, :string, default: nil

  @spec swatch(map()) :: Phoenix.LiveView.Rendered.t()
  def swatch(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class={["w-full h-16 rounded-md", @class]} />
      <div>
        <div class="text-xs font-mono">{@name}</div>
        <div :if={@hex} class="text-xs font-mono text-text-muted">{@hex}</div>
      </div>
    </div>
    """
  end

  attr :token, :string, required: true
  attr :weight, :string, required: true
  attr :size, :string, required: true
  slot :inner_block, required: true

  @spec type_sample(map()) :: Phoenix.LiveView.Rendered.t()
  def type_sample(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-6 border-b border-border pb-4">
      <div class="min-w-0 flex-1">{render_slot(@inner_block)}</div>
      <div class="text-right text-xs font-mono text-text-muted whitespace-nowrap">
        {@token} · {@size} / {@weight}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :bar, :string, required: true

  @spec scale_row(map()) :: Phoenix.LiveView.Rendered.t()
  def scale_row(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <div class="w-12 text-xs font-mono text-text-muted">{@label}</div>
      <div class="w-20 text-xs font-mono text-text-muted">{@value}</div>
      <div class={["h-3 bg-accent rounded-sm", @bar]} />
    </div>
    """
  end

  @spec spacing_scale() :: [{String.t(), String.t(), String.t()}]
  def spacing_scale do
    [
      {"1", "0.25rem", "w-1"},
      {"2", "0.5rem", "w-2"},
      {"3", "0.75rem", "w-3"},
      {"4", "1rem", "w-4"},
      {"6", "1.5rem", "w-6"},
      {"8", "2rem", "w-8"},
      {"12", "3rem", "w-12"},
      {"16", "4rem", "w-16"}
    ]
  end

  @spec rounded_scale() :: [{String.t(), String.t()}]
  def rounded_scale do
    [
      {"none", "rounded-none"},
      {"sm", "rounded-sm"},
      {"md", "rounded-md"},
      {"lg", "rounded-lg"},
      {"pill", "rounded-full"}
    ]
  end
end
