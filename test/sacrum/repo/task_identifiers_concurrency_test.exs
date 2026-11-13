defmodule Sacrum.Repo.TaskIdentifiersConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task, as: TaskSchema
  alias Sacrum.Repo.Schemas.User
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users

  test "concurrent task creation across db sessions allocates unique consecutive numbers" do
    {user_id, first_id, second_id} =
      committed_db(fn ->
        unique = System.unique_integer([:positive])

        {:ok, user} =
          Users.insert(%{
            email: "keys-#{unique}@example.com",
            username: "keys#{unique}",
            password: "password123"
          })

        {:ok, first} = Projects.insert(user, %{name: "First", key_prefix: "FST"})
        {:ok, second} = Projects.insert(user, %{name: "Second", key_prefix: "SND"})
        {user.id, first.id, second.id}
      end)

    try do
      results =
        for(index <- 1..20, project_id <- [first_id, second_id], do: {index, project_id})
        |> Task.async_stream(
          fn {index, project_id} ->
            committed_db(fn ->
              {:ok, task} = Tasks.insert(project_id, user_id, %{title: "Concurrent #{index}"})
              {project_id, task.number}
            end)
          end,
          max_concurrency: 10,
          ordered: false,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for project_id <- [first_id, second_id] do
        numbers = for {^project_id, number} <- results, do: number
        assert Enum.sort(numbers) == Enum.to_list(1..20)
      end
    after
      committed_db(fn ->
        Repo.delete_all(from project in Project, where: project.user_id == ^user_id)
        Repo.delete_all(from user in User, where: user.id == ^user_id)
      end)
    end
  end

  test "enabling numbering while tasks are being created numbers every task once" do
    {user_id, project_id} =
      committed_db(fn ->
        unique = System.unique_integer([:positive])

        {:ok, user} =
          Users.insert(%{
            email: "enable-#{unique}@example.com",
            username: "enable#{unique}",
            password: "password123"
          })

        {:ok, project} = Projects.insert(user, %{name: "Enable"})
        {user.id, project.id}
      end)

    try do
      inserts =
        for index <- 1..20 do
          fn ->
            {:ok, _task} = Tasks.insert(project_id, user_id, %{title: "Concurrent #{index}"})
          end
        end

      enable = fn ->
        project = Repo.get!(Project, project_id)
        {:ok, _project} = Sacrum.Accounts.Projects.update(project, %{key_prefix: "ENB"})
      end

      {first_half, second_half} = Enum.split(inserts, 10)

      (first_half ++ [enable] ++ second_half)
      |> Task.async_stream(fn fun -> committed_db(fun) end,
        max_concurrency: 10,
        timeout: 15_000
      )
      |> Stream.run()

      numbers =
        committed_db(fn ->
          Repo.all(
            from task in TaskSchema, where: task.project_id == ^project_id, select: task.number
          )
        end)

      assert Enum.sort(numbers) == Enum.to_list(1..20)
    after
      committed_db(fn ->
        Repo.delete_all(from project in Project, where: project.user_id == ^user_id)
        Repo.delete_all(from user in User, where: user.id == ^user_id)
      end)
    end
  end

  defp committed_db(fun) when is_function(fun, 0), do: Sandbox.unboxed_run(Repo, fun)
end
