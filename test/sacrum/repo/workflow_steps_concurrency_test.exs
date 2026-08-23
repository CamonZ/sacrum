defmodule Sacrum.Repo.WorkflowStepsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.{Projects, Users, WorkflowSteps, Workflows}

  test "concurrent creates keep one contiguous order" do
    {user_id, project_id, workflow_id} =
      committed_db(fn ->
        unique = System.unique_integer([:positive])

        {:ok, user} =
          Users.insert(%{
            email: "workflow-order-#{unique}@example.com",
            username: "workflow_order_#{unique}",
            password: "password123"
          })

        {:ok, project} = Projects.insert(user, %{name: "Concurrent Project"})
        {:ok, workflow} = Workflows.insert(project, %{name: "Concurrent Workflow"})
        {user.id, project.id, workflow.id}
      end)

    try do
      results =
        1..8
        |> Task.async_stream(
          fn index ->
            committed_db(fn ->
              {:ok, workflow} = Workflows.get(workflow_id)
              WorkflowSteps.insert(workflow, %{name: "Step #{index}"})
            end)
          end,
          max_concurrency: 8,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))

      steps =
        committed_db(fn ->
          WorkflowSteps.all(
            conditions: [workflow_id: workflow_id],
            order_by: [asc: :step_order]
          )
        end)

      assert Enum.map(steps, & &1.step_order) == Enum.to_list(0..7)
    after
      committed_db(fn ->
        Repo.delete_all(from(p in Sacrum.Repo.Schemas.Project, where: p.id == ^project_id))
        Repo.delete_all(from(u in Sacrum.Repo.Schemas.User, where: u.id == ^user_id))
      end)
    end
  end

  defp committed_db(fun), do: Sandbox.unboxed_run(Repo, fun)
end
