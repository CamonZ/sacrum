defmodule SacrumWeb.Router do
  use SacrumWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SacrumWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug SacrumWeb.Plugs.FetchCurrentUser
  end

  pipeline :require_authenticated_user do
    plug SacrumWeb.Plugs.RequireAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :graphql do
    plug :accepts, ["json"]
    plug SacrumWeb.Plugs.ApiAuthPlug
    plug SacrumWeb.Graphql.ContextPlug
  end

  get "/healthz", SacrumWeb.HealthController, :index

  scope "/", SacrumWeb do
    pipe_through :browser

    live_session :public, on_mount: {SacrumWeb.Live.Hooks.AssignCurrentUser, :default} do
      live "/", HomeLive
      live "/sign-in", SignInLive
      live "/not-invited", NotInvitedLive
      live "/auth-error", AuthErrorLive
    end

    get "/auth/google", AuthController, :request
    get "/auth/google/callback", AuthController, :callback
    post "/auth/session", AuthController, :signout
  end

  scope "/", SacrumWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: {SacrumWeb.Live.Hooks.AssignCurrentUser, :require_authenticated} do
      live "/command-center", CommandCenterLive
      live "/tasks", TaskBrowserLive
      live "/workflows", WorkflowBrowserLive
      live "/traces", TracesLive
    end
  end

  scope "/graphql" do
    pipe_through :graphql

    forward "/", Absinthe.Plug,
      schema: SacrumWeb.Graphql.Schema,
      before_send: {SacrumWeb.Graphql.Logger, :log}
  end

  if Mix.env() == :dev do
    scope "/graphiql" do
      pipe_through :api

      forward "/", Absinthe.Plug.GraphiQL,
        schema: SacrumWeb.Graphql.Schema,
        interface: :playground
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sacrum, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev", SacrumWeb do
      pipe_through :browser

      live "/design", DesignSystemLive
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SacrumWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
