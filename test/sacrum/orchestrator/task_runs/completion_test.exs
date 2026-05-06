defmodule Sacrum.Orchestrator.TaskRuns.CompletionTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Orchestrator.TaskRuns.Completion
  alias Sacrum.Repo.Schemas.TaskRun

  test "changeset marks a run completed and preserves supplied outcome attrs" do
    task_run = task_run_struct()

    changed =
      task_run
      |> Completion.changeset(%{
        latest_step_execution_id: Ecto.UUID.generate(),
        outcome_kind: "workflow_completed",
        outcome_context: %{"final_step_id" => Ecto.UUID.generate()}
      })
      |> Ecto.Changeset.apply_changes()

    assert changed.status == :completed
    assert changed.ended_at
    assert changed.latest_step_execution_id
    assert changed.outcome_kind == "workflow_completed"
    assert changed.outcome_context["final_step_id"]
  end

  defp task_run_struct do
    %TaskRun{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      status: :executing
    }
  end
end
