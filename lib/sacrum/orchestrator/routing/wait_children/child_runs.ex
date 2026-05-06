defmodule Sacrum.Orchestrator.Routing.WaitChildren.ChildRuns do
  @moduledoc """
  Child TaskRun creation and lineage reconciliation for wait-children routing.
  """

  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Orchestrator.TaskRuns.Root
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}

  @spec get_or_create(Task.t(), TaskRun.t(), String.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def get_or_create(%Task{} = child, %TaskRun{} = parent_task_run, triggered_by_step_execution_id)
      when is_binary(triggered_by_step_execution_id) do
    case TaskRuns.get_active_for_task(child.user_id, child.id) do
      {:ok, %TaskRun{} = task_run} ->
        reconcile(task_run, parent_task_run, triggered_by_step_execution_id)

      {:error, :not_found} ->
        create(child, parent_task_run, triggered_by_step_execution_id)
    end
  end

  @spec create(Task.t(), TaskRun.t(), binary()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp create(%Task{} = child, %TaskRun{} = parent_task_run, trigger_id) do
    TaskRuns.insert(child.user_id, child.project_id, child.id, %{
      status: :queued,
      parent_task_run_id: parent_task_run.id,
      root_task_run_id: root_task_run_id(parent_task_run),
      triggered_by_step_execution_id: trigger_id
    })
  end

  @spec reconcile(TaskRun.t(), TaskRun.t(), binary()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp reconcile(%TaskRun{} = task_run, %TaskRun{} = parent_task_run, trigger_id) do
    if task_run.parent_task_run_id == parent_task_run.id and
         task_run.root_task_run_id == root_task_run_id(parent_task_run) do
      reconcile_trigger(task_run, trigger_id)
    else
      reject_lineage(task_run)
    end
  end

  @spec reconcile_trigger(TaskRun.t(), binary()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp reconcile_trigger(%TaskRun{triggered_by_step_execution_id: nil} = task_run, trigger_id) do
    stamp_trigger(task_run, trigger_id)
  end

  defp reconcile_trigger(
         %TaskRun{triggered_by_step_execution_id: trigger_id} = task_run,
         trigger_id
       ) do
    Root.validate_dispatchable(task_run)
  end

  defp reconcile_trigger(%TaskRun{} = task_run, _trigger_id) do
    {:error, {:child_task_run_lineage_conflict, task_run.id}}
  end

  @spec reject_lineage(TaskRun.t()) :: {:error, term()}
  defp reject_lineage(%TaskRun{parent_task_run_id: nil, root_task_run_id: nil} = task_run) do
    {:error, {:child_task_run_has_manual_root, task_run.id}}
  end

  defp reject_lineage(%TaskRun{} = task_run) do
    {:error, {:child_task_run_lineage_conflict, task_run.id}}
  end

  @spec stamp_trigger(TaskRun.t(), binary()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp stamp_trigger(%TaskRun{} = task_run, trigger_id) do
    task_run
    |> TaskRun.lineage_changeset(%{triggered_by_step_execution_id: trigger_id})
    |> Repo.update()
    |> case do
      {:ok, task_run} -> Root.validate_dispatchable(task_run)
      error -> error
    end
  end

  @spec root_task_run_id(TaskRun.t()) :: binary()
  defp root_task_run_id(%TaskRun{root_task_run_id: nil, id: id}), do: id
  defp root_task_run_id(%TaskRun{root_task_run_id: root_task_run_id}), do: root_task_run_id
end
