defmodule Sacrum.Orchestrator.TaskRuns.StateTransitions do
  @moduledoc """
  Simple TaskRun status transitions that do not own higher-level orchestration flow.
  """

  alias Sacrum.Repo.Schemas.TaskRun

  @spec waiting_changeset(TaskRun.t(), binary()) :: Ecto.Changeset.t()
  def waiting_changeset(%TaskRun{} = task_run, latest_step_execution_id) do
    TaskRun.update_changeset(task_run, %{
      status: :waiting,
      latest_step_execution_id: latest_step_execution_id
    })
  end

  @spec stopped_changeset(TaskRun.t(), map()) :: Ecto.Changeset.t()
  def stopped_changeset(%TaskRun{} = task_run, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.merge(%{status: :stopped, ended_at: DateTime.utc_now()})
    |> then(&TaskRun.update_changeset(task_run, &1))
  end

  @spec run_boundary_changeset(TaskRun.t(), map()) :: Ecto.Changeset.t()
  def run_boundary_changeset(%TaskRun{} = task_run, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.put(:status, :stopped)
    |> Map.put(:ended_at, DateTime.utc_now())
    |> Map.put(:outcome_kind, "run_boundary")
    |> Map.put_new(:outcome_context, %{})
    |> then(&TaskRun.update_changeset(task_run, &1))
  end
end
