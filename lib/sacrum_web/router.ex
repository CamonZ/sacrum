defmodule SacrumWeb.Router do
  use SacrumWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SacrumWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug SacrumWeb.Plugs.ApiAuthPlug
  end

  pipeline :graphql do
    plug :accepts, ["json"]
    plug SacrumWeb.Plugs.ApiAuthPlug
    plug SacrumWeb.Graphql.ContextPlug
  end

  scope "/", SacrumWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/graphql" do
    pipe_through :graphql

    forward "/", Absinthe.Plug,
      schema: SacrumWeb.Graphql.Schema
  end

  if Mix.env() == :dev do
    scope "/graphiql" do
      pipe_through :api
      forward "/", Absinthe.Plug.GraphiQL,
        schema: SacrumWeb.Graphql.Schema,
        interface: :playground
    end
  end

  scope "/api", SacrumWeb do
    pipe_through :api_authenticated

    resources "/projects", ProjectController, except: [:new, :edit]

    resources "/workflows", WorkflowController, except: [:new, :edit] do
      resources "/transitions", WorkflowTransitionController,
        only: [:create, :delete],
        param: "id",
        name: "transition"
    end

    resources "/workflow-steps", WorkflowStepController, except: [:new, :edit]

    get "/tasks/ready", TaskController, :ready

    resources "/tasks", TaskController, except: [:new, :edit] do
      get "/path", TaskController, :path
      get "/blockers", TaskController, :blockers

      post "/dependencies/:dependency_id", TaskController, :create_dependency
      delete "/dependencies/:dependency_id", TaskController, :delete_dependency

      resources "/sections", SectionController, only: [:create, :update, :delete]
      resources "/refs", CodeRefController, only: [:index, :create, :delete]

      post "/assign-workflow", TaskWorkflowController, :assign
      delete "/assign-workflow", TaskWorkflowController, :unassign
      post "/move-to", TaskWorkflowController, :move_to

      resources "/executions", StepExecutionController, only: [:index, :create]
    end

    resources "/executions", StepExecutionController, only: [:show, :update] do
      resources "/logs", SessionLogController, only: [:index, :create]
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

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SacrumWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
