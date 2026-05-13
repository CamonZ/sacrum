defmodule Sacrum.Realtime.Cdc.ProjectorTest do
  use Sacrum.DataCase, async: false

  import Sacrum.CdcAssertions

  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users

  describe "ProjectChannel CDC projection" do
    test "committed row changes produce ProjectChannel events" do
      project = create_project()
      {:ok, task} = Tasks.insert(project, %{title: "Projected task"})

      :ok = subscribe_project(project.id)

      assert {:ok, [%{event: "task_created", project_id: project_id, status: :dispatched}]} =
               project_insert("tasks", task, lsn: {1, 1})

      assert project_id == project.id

      assert_project_broadcast("task_created", %{
        schema_version: 1,
        id: task.id,
        project_id: project.id,
        title: "Projected task"
      })
    end

    test "rolled-back row changes do not dispatch ProjectChannel events" do
      project = create_project()

      :ok = subscribe_project(project.id)

      assert {:error, :aborted} =
               Repo.transaction(fn ->
                 %Task{project_id: project.id, user_id: project.user_id}
                 |> Task.create_changeset(
                   Tasks.assign_default_workflow_attrs(%{title: "Rolled back"}, project.id)
                 )
                 |> Repo.insert!()

                 Repo.rollback(:aborted)
               end)

      refute_project_broadcast("task_created")
    end
  end

  defp create_project do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "cdc-#{suffix}@example.com",
        username: "cdc#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "CDC Project #{suffix}"})
    project
  end
end
