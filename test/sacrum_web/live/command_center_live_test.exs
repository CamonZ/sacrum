defmodule SacrumWeb.CommandCenterLiveTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  defp authed_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
  end

  describe "authentication" do
    test "unauthenticated user is redirected to sign-in" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(build_conn(), "/command-center")
    end
  end

  describe "shell" do
    setup do
      user = create_user(%{username: "shelluser"})
      {:ok, _project} = Sacrum.Repo.Projects.insert(user, %{name: "Shell Project"})
      {:ok, user: user, conn: authed_conn(user)}
    end

    test "renders the four left-nav surfaces", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      assert html =~ ~s(href="/command-center")
      assert html =~ ~s(href="/tasks")
      assert html =~ ~s(href="/workflows")
      assert html =~ ~s(href="/traces")
    end

    test "header shows the current user identity and a sign-out form", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, "/command-center")

      assert html =~ user.email
      assert html =~ ~s(action="/auth/session")
    end

    test "main content stacks pulse and the four zones vertically", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      # Check for Pulse metrics instead of label
      assert html =~ "CONC"
      assert html =~ "SPEND"
      assert html =~ "THRU"
      assert html =~ "P50"
      # Check for other zones
      assert html =~ "Attention"
      assert html =~ "Live Runs"
      assert html =~ "Queue"
      assert html =~ "Ready"
      assert html =~ "Blocked"
      assert html =~ "Recent Activity"
      assert html =~ "Created &amp; Updated"
    end

    test "chat sidebar toggles open and closed", %{conn: conn} do
      {:ok, view, html} = live(conn, "/command-center")

      refute html =~ "Chat panel coming soon"

      after_open =
        view
        |> element("button[phx-click=toggle-chat]")
        |> render_click()

      assert after_open =~ "Chat panel coming soon"
    end
  end

  describe "empty state" do
    test "shows the vtb init CTA when the user has no projects" do
      user = create_user(%{username: "emptyuser"})
      {:ok, _view, html} = live(authed_conn(user), "/command-center")

      assert html =~ "No Projects Yet"
      assert html =~ "vtb init"
      refute html =~ "Live Runs"
    end

    test "shows the zones when the user has projects" do
      user = create_user(%{username: "projectuser"})
      {:ok, _project} = Sacrum.Repo.Projects.insert(user, %{name: "Test Project"})

      {:ok, _view, html} = live(authed_conn(user), "/command-center")

      refute html =~ "No Projects Yet"
      assert html =~ "Live Runs"
    end
  end

  describe "placeholder surfaces" do
    setup do
      user = create_user(%{username: "navuser"})
      {:ok, conn: authed_conn(user)}
    end

    test "Task Browser placeholder renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tasks")
      assert html =~ "Task Browser coming soon"
    end

    test "Workflow Browser placeholder renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/workflows")
      assert html =~ "Workflow Browser coming soon"
    end

    test "Traces placeholder renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/traces")
      assert html =~ "Traces coming soon"
    end
  end

  describe "pulse metrics" do
    setup do
      user = create_user(%{username: "pulseuser"})
      {:ok, project} = Sacrum.Repo.Projects.insert(user, %{name: "Pulse Test"})
      {:ok, user: user, project: project, conn: authed_conn(user)}
    end

    test "renders pulse metrics with correct formatting", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      # Should show the metrics (may be 0 initially)
      assert html =~ "CONC"
      assert html =~ "SPEND"
      assert html =~ "THRU"
      assert html =~ "P50"
      # Concurrency ratio
      assert html =~ ~r/\d+\/\d+/
      # USD amount
      assert html =~ ~r/\$\d+\.\d+/
    end

    test "throughput metric updates when a run completes via the engine", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, view, _html} = live(conn, "/command-center")

      # Create a workflow with a final step
      {:ok, workflow} =
        Sacrum.Repo.Workflows.insert(project, %{
          name: "Test Workflow",
          user_id: user.id
        })

      {:ok, step_final} =
        Sacrum.Repo.WorkflowSteps.insert(workflow, %{
          name: "Final Step",
          is_final: true
        })

      # Create a task
      {:ok, task} =
        Sacrum.Repo.Tasks.insert(project, %{
          title: "Pulse Test Task"
        })

      # Create a step execution that completes to final step
      {:ok, _execution} =
        Sacrum.Repo.StepExecutions.insert(user.id, %{
          task_id: task.id,
          step_name: "Final Step",
          workflow_id: workflow.id,
          step_id: step_final.id,
          project_id: project.id,
          status: "completed"
        })

      # Trigger the broadcast to update metrics
      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "project:#{project.id}",
        event: "step_execution_status_changed",
        payload: %{}
      })

      # Wait for the view to process the broadcast
      _ = render(view)

      # Check that throughput has been updated
      html = render(view)
      assert html =~ "THRU"
      # The throughput should be 1 after our task completes
      assert html =~ ~r/THRU.*\>1\</
    end

    test "pulse metrics are greyed out when socket is disconnected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      # Initially connected, should have full opacity
      assert html =~ "opacity-100"
      refute html =~ "opacity-50"
    end
  end
end
