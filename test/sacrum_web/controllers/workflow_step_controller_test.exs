defmodule SacrumWeb.WorkflowStepControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Auth

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp authenticate(conn, user) do
    {:ok, token, _api_token} = Auth.create_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    %{conn: conn, user: user, project: project, workflow: workflow}
  end

  describe "GET /api/projects/:pid/workflows/:wid/steps" do
    setup :setup_authenticated

    test "returns 200 with steps list", %{conn: conn, project: project, workflow: workflow} do
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Review", step_order: 2})

      conn = get(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}/steps")

      assert %{"data" => steps} = json_response(conn, 200)
      assert length(steps) == 2
    end
  end

  describe "POST /api/projects/:pid/workflows/:wid/steps" do
    setup :setup_authenticated

    test "creates step and returns 201", %{conn: conn, project: project, workflow: workflow} do
      conn =
        post(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}/steps", %{
          name: "Review",
          goal: "Review the code",
          step_order: 1
        })

      assert %{
               "data" => %{
                 "name" => "Review",
                 "goal" => "Review the code",
                 "step_order" => 1
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing name", %{conn: conn, project: project, workflow: workflow} do
      conn = post(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}/steps", %{})
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/projects/:pid/workflows/:wid/steps/:id" do
    setup :setup_authenticated

    test "updates step and returns 200", %{conn: conn, project: project, workflow: workflow} do
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})

      conn =
        patch(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}/steps/#{step.id}", %{
          name: "Updated Draft",
          is_final: true
        })

      assert %{
               "data" => %{
                 "name" => "Updated Draft",
                 "is_final" => true
               }
             } = json_response(conn, 200)
    end
  end

  describe "DELETE /api/projects/:pid/workflows/:wid/steps/:id" do
    setup :setup_authenticated

    test "removes step and returns 204", %{conn: conn, project: project, workflow: workflow} do
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Draft"})

      conn =
        delete(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}/steps/#{step.id}")

      assert response(conn, 204)
    end
  end
end
