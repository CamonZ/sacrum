defmodule Sacrum.Repo.TaskIdentifiersMigrationTest do
  @moduledoc """
  Rolls the task identifier migration back inside the sandbox transaction,
  reshapes legacy rows, and migrates forward again to verify the backfill. The
  DDL is transactional, so the sandbox rollback restores the schema for other
  tests.
  """

  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Users

  @version 20_261_031_165_811

  test "leaves existing projects unprefixed and their tasks unnumbered until a prefix is set" do
    user = create_user("backfill")
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Vertebrae"})
    {:ok, empty} = Accounts.Projects.insert(user.id, %{name: "Empty"})

    tasks =
      for title <- ["first", "second"] do
        {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: title})
        task
      end

    migrate(:down, @version)
    migrate(:up)

    assert %{key_prefix: nil, last_task_number: 0} = Repo.get!(Project, project.id)
    assert %{key_prefix: nil, last_task_number: 0} = Repo.get!(Project, empty.id)
    assert Enum.map(tasks, &number/1) == [nil, nil]

    assert {:ok, %Project{last_task_number: 2}} =
             project |> reload() |> Accounts.Projects.update(%{key_prefix: "VTB"})

    assert tasks |> Enum.map(&number/1) |> Enum.sort() == [1, 2]
  end

  defp create_user(name) do
    {:ok, user} =
      Users.insert(%{email: "#{name}@example.com", username: name, password: "password123"})

    user
  end

  defp number(task), do: Repo.get!(Task, task.id).number

  defp reload(project), do: Repo.get!(Project, project.id)

  # The migrator holds its lock in the caller while running each migration in
  # a task; the sandbox has one shared connection, so the lock must be off.
  defp migrate(:down, version), do: run_migrations(:down, to: version)
  defp migrate(:up), do: run_migrations(:up, all: true)

  defp run_migrations(direction, opts) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(
        Repo,
        Application.app_dir(:sacrum, "priv/repo/migrations"),
        direction,
        [log: false, migration_lock: false] ++ opts
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end
end
