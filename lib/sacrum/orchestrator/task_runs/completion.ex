defmodule Sacrum.Orchestrator.TaskRuns.Completion do
  @moduledoc """
  Completion state changes for durable TaskRuns.
  """

  alias Sacrum.Repo.Schemas.TaskRun

  @spec changeset(TaskRun.t(), map()) :: Ecto.Changeset.t()
  def changeset(%TaskRun{} = task_run, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.merge(%{status: :completed, ended_at: DateTime.utc_now()})
    |> then(&TaskRun.update_changeset(task_run, &1))
  end
end
