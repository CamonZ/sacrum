defmodule Sacrum.Orchestrator.TaskRuns.Failure do
  @moduledoc """
  Failure state changes and generic outcome metadata for durable TaskRuns.
  """

  alias Sacrum.Orchestrator.TaskRuns.Lookup
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @spec mark_if_active(binary() | TaskRun.t(), term(), map()) ::
          {:ok, TaskRun.t()} | {:ok, :unchanged} | {:error, term()}
  def mark_if_active(task_run_or_id, reason, context \\ %{}) when is_map(context) do
    with {:ok, %TaskRun{} = task_run} <- Lookup.fetch(task_run_or_id) do
      if TaskRunStatus.stoppable?(task_run.status) do
        mark(task_run, reason, context)
      else
        {:ok, :unchanged}
      end
    end
  end

  @spec mark(TaskRun.t(), term(), map()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp mark(%TaskRun{} = task_run, reason, context) do
    task_run
    |> changeset(reason, context)
    |> Repo.update()
    |> Broadcaster.broadcast_task_run(:task_run_updated)
  end

  @spec changeset(TaskRun.t(), term(), map()) :: Ecto.Changeset.t()
  defp changeset(%TaskRun{} = task_run, reason, context) when is_map(context) do
    TaskRun.update_changeset(task_run, %{
      status: :failed,
      ended_at: DateTime.utc_now(),
      outcome_kind: outcome_kind(reason),
      outcome_context: outcome_context(reason, context)
    })
  end

  @spec outcome_context(term(), map()) :: map()
  defp outcome_context(reason, context) do
    context
    |> stringify_context()
    |> Map.put_new("reason", reason_text(reason))
  end

  @spec outcome_kind(term()) :: String.t()
  defp outcome_kind({kind, _reason}) when is_atom(kind), do: Atom.to_string(kind)
  defp outcome_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp outcome_kind(_reason), do: "orchestrator_failure"

  @spec reason_text(term()) :: String.t()
  defp reason_text({_kind, reason}), do: reason_text(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  @spec stringify_context(map()) :: map()
  defp stringify_context(context) do
    Map.new(context, fn {key, value} -> {to_string(key), value} end)
  end
end
