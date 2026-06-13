defmodule Sacrum.Repo.TaskSectionsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  test "concurrent auto-assigned inserts use distinct section_order values across db sessions" do
    {user_id, project_id, task_id} =
      committed_db(fn ->
        {:ok, user} = Users.insert(unique_user_attrs())
        {:ok, project} = Projects.insert(user, %{name: "Committed Project"})
        {:ok, task} = Tasks.insert(project, %{title: "Committed Task"})

        {user.id, project.id, task.id}
      end)

    try do
      results =
        1..6
        |> Task.async_stream(
          fn i ->
            committed_db(fn ->
              task = Tasks.get!(task_id)

              TaskSections.insert(task, %{
                section_type: "testing_criterion",
                content: "Concurrent criterion #{i}"
              })
            end)
          end,
          max_concurrency: 6,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, _section}} -> true
               _other -> false
             end)

      sections =
        committed_db(fn ->
          TaskSections.all(
            conditions: [task_id: task_id, section_type: "testing_criterion"],
            order_by: [asc: :section_order]
          )
        end)

      assert Enum.map(sections, & &1.section_order) == Enum.to_list(0..5)
    after
      cleanup_committed_task(user_id, project_id, task_id)
    end
  end

  defp unique_user_attrs do
    unique = System.unique_integer([:positive])

    %{
      @valid_user_attrs
      | email: "test-#{unique}@example.com",
        username: "testuser#{unique}"
    }
  end

  defp committed_db(fun) when is_function(fun, 0) do
    Sandbox.unboxed_run(Repo, fun)
  end

  defp cleanup_committed_task(user_id, project_id, task_id) do
    committed_db(fn ->
      Repo.delete_all(
        from section in Sacrum.Repo.Schemas.TaskSection,
          where: section.task_id == ^task_id
      )

      Repo.delete_all(from task in Sacrum.Repo.Schemas.Task, where: task.id == ^task_id)

      Repo.delete_all(
        from project in Sacrum.Repo.Schemas.Project, where: project.id == ^project_id
      )

      Repo.delete_all(from user in Sacrum.Repo.Schemas.User, where: user.id == ^user_id)
    end)
  end
end
