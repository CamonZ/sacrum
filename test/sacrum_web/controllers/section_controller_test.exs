defmodule SacrumWeb.SectionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    %{conn: conn, user: user, project: project, task: task}
  end

  describe "POST /api/tasks/:task_id/sections" do
    setup :setup_authenticated

    test "creates section and returns 201", %{conn: conn, task: task} do
      conn =
        post(conn, ~p"/api/tasks/#{task.id}/sections", %{
          section_type: "testing_criteria",
          content: "Verify the feature works"
        })

      assert %{
               "data" => %{
                 "section_type" => "testing_criteria",
                 "content" => "Verify the feature works",
                 "done" => false
               }
             } = json_response(conn, 201)
    end

    test "creates section with optional fields", %{conn: conn, task: task} do
      conn =
        post(conn, ~p"/api/tasks/#{task.id}/sections", %{
          section_type: "implementation_notes",
          content: "Use the new API",
          section_order: 5
        })

      assert %{"data" => %{"section_order" => 5}} = json_response(conn, 201)
    end

    test "returns 422 when missing required fields", %{conn: conn, task: task} do
      conn = post(conn, ~p"/api/tasks/#{task.id}/sections", %{section_type: "notes"})
      assert %{"errors" => %{"content" => _}} = json_response(conn, 422)
    end

    test "returns 404 when task does not exist", %{conn: conn} do
      conn =
        post(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/sections", %{
          section_type: "notes",
          content: "test"
        })

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/tasks/:task_id/sections/:id" do
    setup :setup_authenticated

    test "removes section and returns 204", %{conn: conn, task: task} do
      {:ok, section} =
        TaskSections.insert(task, %{section_type: "notes", content: "To be deleted"})

      conn = delete(conn, ~p"/api/tasks/#{task.id}/sections/#{section.id}")
      assert response(conn, 204)

      # Verify section was deleted
      assert {:error, :not_found} = TaskSections.get(section.id)
    end

    test "returns 404 when section does not exist", %{conn: conn, task: task} do
      conn = delete(conn, ~p"/api/tasks/#{task.id}/sections/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "returns 404 when task does not exist", %{conn: conn, task: task} do
      {:ok, section} = TaskSections.insert(task, %{section_type: "notes", content: "test"})

      conn = delete(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/sections/#{section.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for another user's section", %{conn: _conn, task: task} do
      # Create section for original task
      {:ok, section} = TaskSections.insert(task, %{section_type: "notes", content: "test"})

      # Create another user and authenticate
      other_user =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      other_conn = build_conn() |> authenticate(other_user)

      conn = delete(other_conn, ~p"/api/tasks/#{task.id}/sections/#{section.id}")
      assert json_response(conn, 404)
    end
  end
end
