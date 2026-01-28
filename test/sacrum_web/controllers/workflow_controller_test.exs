defmodule SacrumWeb.WorkflowControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
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
    %{conn: conn, user: user, project: project}
  end

  describe "unauthenticated requests" do
    test "returns 401 without auth header", %{conn: conn} do
      project_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/projects/#{project_id}/workflows")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/projects/:project_id/workflows" do
    setup :setup_authenticated

    test "returns 200 with workflow list", %{conn: conn, project: project} do
      {:ok, _} = Workflows.insert(project, %{name: "Workflow 1"})
      {:ok, _} = Workflows.insert(project, %{name: "Workflow 2"})

      conn = get(conn, ~p"/api/projects/#{project.id}/workflows")

      assert %{"data" => workflows} = json_response(conn, 200)
      assert length(workflows) == 2
    end

    test "returns empty list when no workflows", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/workflows")
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other"})

      conn = get(conn, ~p"/api/projects/#{other_project.id}/workflows")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/projects/:project_id/workflows/:id" do
    setup :setup_authenticated

    test "returns 200 with workflow JSON", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "My Workflow", description: "Desc"})

      conn = get(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}")

      assert %{
               "data" => %{
                 "id" => id,
                 "name" => "My Workflow",
                 "description" => "Desc"
               }
             } = json_response(conn, 200)

      assert id == workflow.id
    end

    test "returns 404 for nonexistent workflow", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/workflows/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/projects/:project_id/workflows" do
    setup :setup_authenticated

    test "returns 201 with workflow JSON for valid params", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/projects/#{project.id}/workflows", %{
          name: "New Workflow",
          description: "A new workflow"
        })

      assert %{
               "data" => %{
                 "id" => _id,
                 "name" => "New Workflow",
                 "description" => "A new workflow"
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing name", %{conn: conn, project: project} do
      conn = post(conn, ~p"/api/projects/#{project.id}/workflows", %{})
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "PUT /api/projects/:project_id/workflows/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "Original"})

      conn =
        put(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}", %{
          name: "Updated",
          description: "New desc"
        })

      assert %{
               "data" => %{
                 "name" => "Updated",
                 "description" => "New desc"
               }
             } = json_response(conn, 200)
    end
  end

  describe "DELETE /api/projects/:project_id/workflows/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, project: project} do
      {:ok, workflow} = Workflows.insert(project, %{name: "To Delete"})
      conn = delete(conn, ~p"/api/projects/#{project.id}/workflows/#{workflow.id}")
      assert response(conn, 204)
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, other_project} = Projects.insert(other_user, %{name: "Other"})
      {:ok, workflow} = Workflows.insert(other_project, %{name: "Secret"})

      conn = delete(conn, ~p"/api/projects/#{other_project.id}/workflows/#{workflow.id}")
      assert json_response(conn, 404)
    end
  end
end
