defmodule SacrumWeb.TaskControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
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
      conn = get(conn, ~p"/api/projects/#{project_id}/tasks")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/projects/:project_id/tasks" do
    setup :setup_authenticated

    test "returns 200 with task list", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 2
    end

    test "returns empty list for project with no tasks", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/tasks")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "returns 200 with task JSON", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "My Task"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}")

      assert %{
               "data" => %{
                 "id" => id,
                 "title" => "My Task",
                 "short_id" => short_id
               }
             } = json_response(conn, 200)

      assert id == task.id
      assert short_id =~ ~r/^x[a-f0-9]{6}$/
    end

    test "returns 404 for nonexistent task", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/projects/:project_id/tasks" do
    setup :setup_authenticated

    test "returns 201 with valid params", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/projects/#{project.id}/tasks", %{
          title: "New Task",
          description: "A description",
          level: "ticket"
        })

      assert %{
               "data" => %{
                 "title" => "New Task",
                 "description" => "A description",
                 "level" => "ticket",
                 "short_id" => _
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing title", %{conn: conn, project: project} do
      conn = post(conn, ~p"/api/projects/#{project.id}/tasks", %{})
      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
    end
  end

  describe "PUT /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      conn =
        put(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}", %{
          title: "Updated",
          description: "New desc"
        })

      assert %{
               "data" => %{
                 "title" => "Updated",
                 "description" => "New desc"
               }
             } = json_response(conn, 200)
    end
  end

  describe "DELETE /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
      conn = delete(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}")
      assert response(conn, 204)
    end
  end
end
