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

  scope "/", SacrumWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", SacrumWeb do
    pipe_through :api_authenticated

    resources "/projects", ProjectController, except: [:new, :edit] do
      resources "/workflows", WorkflowController, except: [:new, :edit] do
        resources "/steps", WorkflowStepController, except: [:new, :edit, :show]
      end

      resources "/workflow-transitions", WorkflowTransitionController,
        only: [:index, :create, :delete]

      get "/tasks/ready", TaskController, :ready

      resources "/tasks", TaskController, except: [:new, :edit] do
        resources "/sections", TaskSectionController, except: [:new, :edit, :show]
        resources "/refs", CodeRefController, only: [:index, :create, :delete]

        put "/parent", TaskRelationshipController, :set_parent
        delete "/parent", TaskRelationshipController, :remove_parent
        resources "/dependencies", TaskRelationshipController, only: [:create, :delete]
        get "/blockers", TaskRelationshipController, :blockers
        get "/path", TaskRelationshipController, :path

        post "/assign_workflow", TaskWorkflowController, :assign
        delete "/assign_workflow", TaskWorkflowController, :unassign
        post "/advance", TaskWorkflowController, :advance
        post "/retreat", TaskWorkflowController, :retreat
        post "/reject", TaskWorkflowController, :reject

        resources "/executions", StepExecutionController, only: [:index]
      end

      resources "/executions", StepExecutionController, only: [:show] do
        resources "/logs", SessionLogController, only: [:index]
      end
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
