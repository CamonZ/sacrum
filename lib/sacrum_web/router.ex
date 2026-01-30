defmodule SacrumWeb.Router do
  use SacrumWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug SacrumWeb.Plugs.ApiAuthPlug
  end

  scope "/", SacrumWeb do
    pipe_through :api

    get "/", PageController, :home
  end

  scope "/api", SacrumWeb do
    pipe_through :api_authenticated

    resources "/projects", ProjectController, except: [:new, :edit]

    resources "/workflows", WorkflowController, except: [:new, :edit]

    resources "/workflow-steps", WorkflowStepController, except: [:new, :edit]

    get "/tasks/ready", TaskController, :ready

    resources "/tasks", TaskController, except: [:new, :edit] do
      resources "/refs", CodeRefController, only: [:index, :create, :delete]

      get "/blockers", TaskController, :blockers
      get "/path", TaskController, :path
      get "/tree", TaskController, :tree

      post "/assign-workflow", TaskWorkflowController, :assign
      delete "/assign-workflow", TaskWorkflowController, :unassign
      post "/move-to", TaskWorkflowController, :move_to

      resources "/executions", StepExecutionController, only: [:index]
    end

    resources "/executions", StepExecutionController, only: [:show] do
      resources "/logs", SessionLogController, only: [:index]
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
      pipe_through :api

      live_dashboard "/dashboard", metrics: SacrumWeb.Telemetry
    end
  end
end
