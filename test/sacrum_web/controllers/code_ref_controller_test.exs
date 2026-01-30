defmodule SacrumWeb.CodeRefControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.CodeRefs

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    %{conn: conn, user: user, project: project, task: task}
  end

  describe "GET /api/tasks/:tid/refs" do
    setup :setup_authenticated

    test "returns 200 with refs list", %{conn: conn, task: task} do
      {:ok, _} = CodeRefs.insert_for_task(task, %{path: "lib/foo.ex"})

      conn = get(conn, ~p"/api/tasks/#{task.id}/refs")
      assert %{"data" => [%{"path" => "lib/foo.ex"}]} = json_response(conn, 200)
    end
  end

  describe "POST /api/tasks/:tid/refs" do
    setup :setup_authenticated

    test "creates code ref and returns 201", %{conn: conn, task: task} do
      conn =
        post(conn, ~p"/api/tasks/#{task.id}/refs", %{
          path: "lib/bar.ex",
          line_start: 5,
          line_end: 15,
          name: "my_function"
        })

      assert %{"data" => %{"path" => "lib/bar.ex", "line_start" => 5}} =
               json_response(conn, 201)
    end
  end

  describe "DELETE /api/tasks/:tid/refs/:id" do
    setup :setup_authenticated

    test "removes code ref and returns 204", %{conn: conn, task: task} do
      {:ok, ref} = CodeRefs.insert_for_task(task, %{path: "lib/temp.ex"})

      conn = delete(conn, ~p"/api/tasks/#{task.id}/refs/#{ref.id}")
      assert response(conn, 204)
    end
  end
end
