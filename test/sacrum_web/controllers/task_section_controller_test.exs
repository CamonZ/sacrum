defmodule SacrumWeb.TaskSectionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections
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
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    %{conn: conn, user: user, project: project, task: task}
  end

  describe "GET /api/tasks/:tid/sections" do
    setup :setup_authenticated

    test "returns 200 with sections list", %{conn: conn, task: task} do
      {:ok, _} = TaskSections.insert(task, %{section_type: "goal", content: "Goal 1"})

      conn = get(conn, ~p"/api/tasks/#{task.id}/sections")
      assert %{"data" => [%{"section_type" => "goal"}]} = json_response(conn, 200)
    end
  end

  describe "POST /api/tasks/:tid/sections" do
    setup :setup_authenticated

    test "creates section and returns 201", %{conn: conn, task: task} do
      conn =
        post(conn, ~p"/api/tasks/#{task.id}/sections", %{
          section_type: "step",
          content: "Do the thing"
        })

      assert %{"data" => %{"section_type" => "step", "content" => "Do the thing"}} =
               json_response(conn, 201)
    end
  end

  describe "PATCH /api/tasks/:tid/sections/:id" do
    setup :setup_authenticated

    test "updates section and returns 200", %{conn: conn, task: task} do
      {:ok, section} = TaskSections.insert(task, %{section_type: "goal", content: "Original"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}/sections/#{section.id}", %{
          content: "Updated"
        })

      assert %{"data" => %{"content" => "Updated"}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/tasks/:tid/sections/:id" do
    setup :setup_authenticated

    test "removes section and returns 204", %{conn: conn, task: task} do
      {:ok, section} = TaskSections.insert(task, %{section_type: "goal", content: "Temp"})

      conn = delete(conn, ~p"/api/tasks/#{task.id}/sections/#{section.id}")
      assert response(conn, 204)
    end
  end
end
