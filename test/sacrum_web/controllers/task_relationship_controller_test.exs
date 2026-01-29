defmodule SacrumWeb.TaskRelationshipControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskDependencies
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
    {:ok, task} = Tasks.insert(project, %{title: "Task A"})
    %{conn: conn, user: user, project: project, task: task}
  end

  describe "PUT /api/tasks/:tid/parent" do
    setup :setup_authenticated

    test "sets parent and returns 200", %{conn: conn, project: project, task: task} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent Task"})

      conn =
        put(conn, ~p"/api/tasks/#{task.id}/parent", %{parent_id: parent.id})

      assert %{"data" => %{"id" => _}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/tasks/:tid/parent" do
    setup :setup_authenticated

    test "removes parent and returns 204", %{conn: conn, project: project, task: task} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent Task"})
      Sacrum.Repo.TaskHierarchy.set_parent(task, parent)

      conn = delete(conn, ~p"/api/tasks/#{task.id}/parent")
      assert response(conn, 204)
    end
  end

  describe "POST /api/tasks/:tid/dependencies" do
    setup :setup_authenticated

    test "creates dependency and returns 201", %{conn: conn, project: project, task: task} do
      {:ok, dep_task} = Tasks.insert(project, %{title: "Dependency"})

      conn =
        post(conn, ~p"/api/tasks/#{task.id}/dependencies", %{depends_on_id: dep_task.id})

      assert %{"data" => %{"task_id" => _, "depends_on_id" => _}} = json_response(conn, 201)
    end

    test "returns 422 for circular dependency", %{conn: conn, project: project, task: task} do
      {:ok, task_b} = Tasks.insert(project, %{title: "Task B"})
      {:ok, _} = TaskDependencies.add_dependency(task_b, task)

      conn =
        post(conn, ~p"/api/tasks/#{task.id}/dependencies", %{depends_on_id: task_b.id})

      assert %{"errors" => %{"depends_on_id" => _}} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/tasks/:tid/dependencies/:id" do
    setup :setup_authenticated

    test "removes dependency and returns 204", %{conn: conn, project: project, task: task} do
      {:ok, dep_task} = Tasks.insert(project, %{title: "Dependency"})
      {:ok, _} = TaskDependencies.add_dependency(task, dep_task)

      conn = delete(conn, ~p"/api/tasks/#{task.id}/dependencies/#{dep_task.id}")
      assert response(conn, 204)
    end
  end

  describe "GET /api/tasks/:tid/blockers" do
    setup :setup_authenticated

    test "returns transitive blockers", %{conn: conn, project: project, task: task} do
      {:ok, blocker1} = Tasks.insert(project, %{title: "Blocker 1"})
      {:ok, blocker2} = Tasks.insert(project, %{title: "Blocker 2"})
      {:ok, _} = TaskDependencies.add_dependency(task, blocker1)
      {:ok, _} = TaskDependencies.add_dependency(blocker1, blocker2)

      conn = get(conn, ~p"/api/tasks/#{task.id}/blockers")

      assert %{"data" => blockers} = json_response(conn, 200)
      assert length(blockers) == 2
    end
  end

  describe "GET /api/tasks/:tid/path" do
    setup :setup_authenticated

    test "returns shortest dependency path", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})
      {:ok, c} = Tasks.insert(project, %{title: "C"})
      {:ok, _} = TaskDependencies.add_dependency(a, b)
      {:ok, _} = TaskDependencies.add_dependency(b, c)

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{c.id}")
      assert %{"data" => %{"path" => path}} = json_response(conn, 200)
      assert length(path) == 3
      assert path == [a.id, b.id, c.id]
    end

    test "returns empty path when no dependency path exists", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{b.id}")
      assert %{"data" => %{"path" => []}} = json_response(conn, 200)
    end

    test "returns single-element path for direct dependency", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})
      {:ok, _} = TaskDependencies.add_dependency(a, b)

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{b.id}")
      assert %{"data" => %{"path" => path}} = json_response(conn, 200)
      assert path == [a.id, b.id]
    end

    test "returns 404 if target task does not exist", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "returns 422 when to param is missing", %{conn: conn, task: task} do
      conn = get(conn, ~p"/api/tasks/#{task.id}/path")
      assert json_response(conn, 422)
    end
  end
end
