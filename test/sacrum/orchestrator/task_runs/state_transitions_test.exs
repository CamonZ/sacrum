defmodule Sacrum.Orchestrator.TaskRuns.StateTransitionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Orchestrator.TaskRuns.StateTransitions
  alias Sacrum.Repo.Schemas.TaskRun

  test "waiting_changeset marks a run waiting and records latest step execution" do
    latest_execution_id = Ecto.UUID.generate()

    changed =
      task_run_struct()
      |> StateTransitions.waiting_changeset(latest_execution_id)
      |> Ecto.Changeset.apply_changes()

    assert changed.status == :waiting
    assert changed.latest_step_execution_id == latest_execution_id
  end

  test "stopped_changeset marks a run stopped with stop timing" do
    stop_requested_at = DateTime.utc_now()

    changed =
      task_run_struct()
      |> StateTransitions.stopped_changeset(%{stop_requested_at: stop_requested_at})
      |> Ecto.Changeset.apply_changes()

    assert changed.status == :stopped
    assert changed.stop_requested_at == stop_requested_at
    assert changed.ended_at
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
