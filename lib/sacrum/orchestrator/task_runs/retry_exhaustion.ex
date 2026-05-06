defmodule Sacrum.Orchestrator.TaskRuns.RetryExhaustion do
  @moduledoc """
  Retry-exhausted TaskRun finalization.
  """

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Orchestrator.TaskRuns.Lookup
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @outcome_kind "retry_exhausted"

  @spec mark(binary() | TaskRun.t(), binary() | nil, map()) ::
          {:ok, TaskRun.t()} | {:ok, :unchanged} | {:error, term()}
  def mark(task_run_or_id, failed_execution_id, attrs \\ %{}) when is_map(attrs) do
    with {:ok, %TaskRun{} = task_run} <- Lookup.fetch(task_run_or_id) do
      mark_if_stoppable(task_run, failed_execution_id, attrs)
    end
  end

  @spec changeset(TaskRun.t(), StepExecution.t() | nil, map()) :: Ecto.Changeset.t()
  def changeset(%TaskRun{} = task_run, failed_execution, attrs \\ %{}) when is_map(attrs) do
    base_attrs = %{
      status: :failed,
      ended_at: DateTime.utc_now(),
      outcome_kind: @outcome_kind,
      outcome_context: outcome_context(failed_execution, attrs)
    }

    update_attrs = maybe_put_latest_step_execution_id(base_attrs, failed_execution)

    TaskRun.update_changeset(task_run, update_attrs)
  end

  @spec mark_if_stoppable(TaskRun.t(), binary() | nil, map()) ::
          {:ok, TaskRun.t()} | {:ok, :unchanged} | {:error, term()}
  defp mark_if_stoppable(task_run, failed_execution_id, attrs) do
    if TaskRunStatus.stoppable?(task_run.status) do
      persist(task_run, failed_execution_id, attrs)
    else
      {:ok, :unchanged}
    end
  end

  @spec persist(TaskRun.t(), binary() | nil, map()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp persist(task_run, failed_execution_id, attrs) do
    failed_execution = get_task_run_execution(task_run, failed_execution_id)
    attrs = Map.put(attrs, :failed_execution_id, failed_execution_id)

    task_run
    |> changeset(failed_execution, attrs)
    |> Repo.update()
    |> Broadcaster.broadcast_task_run(:task_run_updated)
  end

  @spec get_task_run_execution(TaskRun.t(), binary() | nil | term()) :: StepExecution.t() | nil
  defp get_task_run_execution(_task_run, nil), do: nil

  defp get_task_run_execution(
         %TaskRun{id: task_run_id, user_id: user_id, project_id: project_id},
         failed_execution_id
       )
       when is_binary(failed_execution_id) do
    case StepExecutions.get_by(user_id,
           conditions: [
             id: failed_execution_id,
             task_run_id: task_run_id,
             project_id: project_id
           ]
         ) do
      {:ok, %StepExecution{} = execution} -> execution
      {:error, :not_found} -> nil
    end
  end

  defp get_task_run_execution(_task_run, _failed_execution_id), do: nil

  @spec maybe_put_latest_step_execution_id(map(), StepExecution.t() | nil | term()) :: map()
  defp maybe_put_latest_step_execution_id(attrs, %StepExecution{id: id}) when is_binary(id),
    do: Map.put(attrs, :latest_step_execution_id, id)

  defp maybe_put_latest_step_execution_id(attrs, _failed_execution), do: attrs

  @spec outcome_context(StepExecution.t() | nil, map()) :: map()
  defp outcome_context(failed_execution, attrs) do
    attrs
    |> base_context(failed_execution)
    |> compact_context()
  end

  @spec base_context(map(), StepExecution.t() | nil) :: map()
  defp base_context(attrs, failed_execution) do
    %{
      "failed_execution_id" => Map.get(attrs, :failed_execution_id),
      "current_attempt" => Map.get(attrs, :current_attempt) || Map.get(attrs, :attempt),
      "max_attempts" => Map.get(attrs, :max_attempts),
      "task_id" => Map.get(attrs, :task_id),
      "current_step_id" => Map.get(attrs, :current_step_id),
      "execution_found" => match?(%StepExecution{}, failed_execution)
    }
  end

  @spec compact_context(map()) :: map()
  defp compact_context(context) do
    Map.reject(context, fn {_key, value} -> is_nil(value) end)
  end
end
