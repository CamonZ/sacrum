defmodule SacrumWeb.ProjectControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    %{conn: conn, user: user}
  end

  describe "unauthenticated requests" do
    test "all endpoints return 401 without auth header", %{conn: conn} do
      conn = get(conn, ~p"/api/projects")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/projects" do
    setup :setup_authenticated

    test "returns 200 with list of current user projects only", %{conn: conn, user: user} do
      {:ok, project} = Projects.insert(user, %{name: "My Project"})

      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, _} = Projects.insert(other_user, %{name: "Other Project"})

      conn = get(conn, ~p"/api/projects")
      assert %{"data" => [%{"id" => id, "name" => "My Project"}]} = json_response(conn, 200)
      assert id == project.id
    end

    test "returns empty list when user has no projects", %{conn: conn} do
      conn = get(conn, ~p"/api/projects")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/projects/:id" do
    setup :setup_authenticated

    test "returns 200 with project JSON", %{conn: conn, user: user} do
      {:ok, project} = Projects.insert(user, %{name: "My Project"})
      conn = get(conn, ~p"/api/projects/#{project.id}")

      assert %{
               "data" => %{
                 "id" => id,
                 "name" => "My Project",
                 "slug" => "my-project"
               }
             } = json_response(conn, 200)

      assert id == project.id
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, project} = Projects.insert(other_user, %{name: "Other Project"})

      conn = get(conn, ~p"/api/projects/#{project.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for nonexistent project", %{conn: conn} do
      conn = get(conn, ~p"/api/projects/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/projects" do
    setup :setup_authenticated

    test "returns 201 with project JSON for valid params", %{conn: conn} do
      conn = post(conn, ~p"/api/projects", %{name: "New Project", description: "A description"})

      assert %{
               "data" => %{
                 "id" => _id,
                 "name" => "New Project",
                 "slug" => "new-project",
                 "description" => "A description"
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing name", %{conn: conn} do
      conn = post(conn, ~p"/api/projects", %{})
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end

    test "returns 422 with duplicate slug", %{conn: conn, user: user} do
      {:ok, _} = Projects.insert(user, %{name: "My Project"})
      conn = post(conn, ~p"/api/projects", %{name: "My Project"})
      assert %{"errors" => %{"slug" => _}} = json_response(conn, 422)
    end
  end

  describe "PUT /api/projects/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, user: user} do
      {:ok, project} = Projects.insert(user, %{name: "Original"})

      conn =
        put(conn, ~p"/api/projects/#{project.id}", %{
          name: "Updated",
          description: "New description"
        })

      assert %{
               "data" => %{
                 "name" => "Updated",
                 "description" => "New description"
               }
             } = json_response(conn, 200)
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, project} = Projects.insert(other_user, %{name: "Other"})

      conn = put(conn, ~p"/api/projects/#{project.id}", %{name: "Hacked"})
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/projects/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, user: user} do
      {:ok, project} = Projects.insert(user, %{name: "To Delete"})
      conn = delete(conn, ~p"/api/projects/#{project.id}")
      assert response(conn, 204)
    end

    test "returns 404 for another user's project", %{conn: conn} do
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {:ok, project} = Projects.insert(other_user, %{name: "Other"})

      conn = delete(conn, ~p"/api/projects/#{project.id}")
      assert json_response(conn, 404)
    end
  end
end
