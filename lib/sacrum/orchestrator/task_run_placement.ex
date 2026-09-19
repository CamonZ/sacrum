defmodule Sacrum.Orchestrator.TaskRunPlacement do
  @moduledoc """
  Resolves the daemon placement for a task-run tree.

  A child task keeps its own durable workspace, but admission for its run uses
  the root task's workspace daemon so every step in the tree shares one
  in-memory placement group.
  """

  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, Task, TaskRun}

  @doc """
  Builds the admission snapshot for a task run before dispatch.

  The dispatcher consumes these values; it does not resolve placement or
  daemon configuration itself.
  """
  @spec admission_options(Task.t(), TaskRun.t()) :: keyword()
  def admission_options(%Task{} = task, %TaskRun{} = task_run) do
    {scope, daemon_id} =
      case TaskRuns.get_concurrency_scope(task_run) do
        {:ok, %{id: root_id, max_concurrency: limit} = scope}
        when is_integer(limit) and limit > 0 ->
          {[task_group_id: root_id, root_task_run_id: root_id, max_concurrency: limit],
           daemon_id(task, scope)}

        {:ok, %{id: root_id} = scope} ->
          {[task_group_id: root_id], daemon_id(task, scope)}

        _ ->
          {[], Task.workspace_daemon(task)}
      end

    [
      daemon_id: daemon_id,
      daemon_max_concurrency: daemon_max_concurrency(daemon_id)
    ] ++ scope
  end

  @spec daemon_id(
          Task.t(),
          %{id: String.t(), max_concurrency: pos_integer() | nil} | nil
        ) :: String.t() | nil
  def daemon_id(%Task{} = task, %{id: root_task_run_id}) do
    case Repo.get(TaskRun, root_task_run_id) do
      %TaskRun{task_id: root_task_id} -> root_task_daemon(task, root_task_id)
      _ -> Task.workspace_daemon(task)
    end
  end

  def daemon_id(%Task{} = task, _scope), do: Task.workspace_daemon(task)

  defp root_task_daemon(task, task_id) when task_id == task.id, do: Task.workspace_daemon(task)

  defp root_task_daemon(task, task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = root_task -> Task.workspace_daemon(root_task)
      _ -> Task.workspace_daemon(task)
    end
  end

  defp daemon_max_concurrency(nil), do: nil

  defp daemon_max_concurrency(daemon_id) do
    case Repo.get(Daemon, daemon_id) do
      %Daemon{max_concurrency: max_concurrency} -> max_concurrency
      _ -> nil
    end
  end
end
