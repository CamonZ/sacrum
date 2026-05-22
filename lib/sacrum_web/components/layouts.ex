defmodule SacrumWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SacrumWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map,
    default: nil,
    doc: "the current authenticated user"

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <%= if @current_user do %>
            <li>
              <form action="/auth/session" method="post" class="inline">
                <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                <button type="submit" class="btn btn-sm btn-ghost">
                  Sign out
                </button>
              </form>
            </li>
          <% else %>
            <li>
              <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
                Get Started <span aria-hidden="true">&rarr;</span>
              </a>
            </li>
          <% end %>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @nav_items [
    {:dashboard, "Dashboard", "hero-home", "/dashboard"}
  ]

  @doc """
  Renders the authenticated app shell: top scope strip, left icon nav,
  header with user menu, optional right chat sidebar, and the main slot.
  """
  attr :flash, :map, required: true
  attr :current_user, :map, required: true
  attr :active, :atom, required: true, doc: "active left-nav surface"
  slot :inner_block, required: true

  @spec app_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def app_shell(assigns) do
    assigns = assign(assigns, :nav_items, @nav_items)

    ~H"""
    <div class="h-screen bg-bg text-text-primary font-sans flex flex-col overflow-hidden">
      <header class="h-14 border-b border-border bg-surface flex items-center justify-end px-4 sm:px-6 lg:px-8 flex-shrink-0">
        <div class="flex items-center gap-4">
          <div class="text-xs text-text-muted">
            {@current_user.name || @current_user.email}
          </div>
          <form action="/auth/session" method="post" class="inline">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button
              type="submit"
              class="cursor-pointer text-xs text-text-secondary hover:text-text-primary transition-colors"
            >
              Sign out
            </button>
          </form>
        </div>
      </header>

      <div class="flex flex-1 overflow-hidden">
        <nav class="w-14 border-r border-border bg-surface flex flex-col items-center py-4 gap-2 flex-shrink-0">
          <.link
            :for={{key, label, icon, path} <- @nav_items}
            navigate={path}
            title={label}
            class={[
              "cursor-pointer w-10 h-10 rounded-lg flex items-center justify-center transition-all",
              "border border-border hover:border-accent hover:bg-surface-raised",
              @active == key && "bg-accent text-accent-fg border-accent"
            ]}
          >
            <.icon name={icon} class="w-5 h-5" />
          </.link>
        </nav>

        <main class="flex-1 overflow-auto">{render_slot(@inner_block)}</main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
