defmodule Sacrum.Orchestrator.TaskRunPlacement do
  @moduledoc """
  Resolves the daemon placement for a task-run tree.

  A child task keeps its own durable workspace, but admission and authenticated
  execution commands use the root task's daemon. A pre-existing child
  assignment to a different daemon is an explicit conflict.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, StepExecution, Task, TaskRun}
  alias Sacrum.Tasks.Placement

  @doc """
  Resolves placement once for a task-run admission attempt.

  The task row is refreshed before placement so direct dispatch sees a workspace
  assigned immediately before the process started. Root lookup, conflict
  validation, child assignment, and daemon limit lookup are kept in this one
  placement pass.
  """
  @spec resolve_admission_options(Task.t(), TaskRun.t()) ::
          {:ok, Task.t(), keyword()} | {:error, atom() | tuple()}
  def resolve_admission_options(%Task{} = task, %TaskRun{} = task_run) do
    task = refresh_task(task)

    with {:ok, root_task, root_task_run} <- placement_context(task, task_run),
         root_daemon when is_binary(root_daemon) <- Task.workspace_daemon(root_task),
         :ok <- Placement.validate_workspace_owner(task.user_id, %{daemon_id: root_daemon}),
         :ok <- validate_child_daemon(task, root_task, root_daemon),
         {:ok, task} <- maybe_place_child(task, root_task, root_daemon),
         scope <- concurrency_scope(root_task_run) do
      scope_options =
        case scope do
          %{id: root_id, max_concurrency: limit}
          when is_integer(limit) and limit > 0 ->
            [task_group_id: root_id, root_task_run_id: root_id, max_concurrency: limit]

          %{id: root_id} ->
            [task_group_id: root_id]
        end

      {:ok, task,
       [
         daemon_id: root_daemon,
         daemon_max_concurrency: daemon_max_concurrency(root_daemon)
       ] ++ scope_options}
    else
      nil -> {:error, :workspace_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp placement_context(task, %TaskRun{root_task_run_id: nil} = task_run) do
    if task_run.task_id == task.id do
      {:ok, task, task_run}
    else
      with {:ok, root_task} <- fetch_task_by_id(task_run.task_id, task.user_id, task.project_id) do
        {:ok, root_task, task_run}
      end
    end
  end

  defp placement_context(task, %TaskRun{root_task_run_id: root_task_run_id}) do
    with %TaskRun{} = root_task_run <-
           Repo.get_by(TaskRun,
             id: root_task_run_id,
             user_id: task.user_id,
             project_id: task.project_id
           ),
         {:ok, root_task} <-
           fetch_task_by_id(root_task_run.task_id, task.user_id, task.project_id) do
      {:ok, root_task, root_task_run}
    else
      nil -> {:error, :root_task_run_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp concurrency_scope(%TaskRun{id: id, max_concurrency: max_concurrency}),
    do: %{id: id, max_concurrency: max_concurrency}

  @doc "Looks up the root daemon, or the task daemon for a legacy execution, in one scoped query."
  @spec daemon_id_for_execution(StepExecution.t()) ::
          String.t() | {:error, atom()}
  def daemon_id_for_execution(%StepExecution{task_run_id: nil} = execution) do
    Repo.one(
      from task in Task,
        where:
          task.id == ^execution.task_id and task.user_id == ^execution.user_id and
            task.project_id == ^execution.project_id,
        select: task.workspace_daemon_id
    ) || {:error, :workspace_required}
  end

  def daemon_id_for_execution(%StepExecution{} = execution) do
    Repo.one(
      from run in TaskRun,
        join: root_run in TaskRun,
        on: root_run.id == coalesce(run.root_task_run_id, run.id),
        join: root_task in Task,
        on: root_task.id == root_run.task_id,
        where: [
          id: ^execution.task_run_id,
          task_id: ^execution.task_id,
          user_id: ^execution.user_id,
          project_id: ^execution.project_id
        ],
        where:
          root_run.user_id == ^execution.user_id and
            root_run.project_id == ^execution.project_id and
            root_task.user_id == ^execution.user_id and
            root_task.project_id == ^execution.project_id,
        select: root_task.workspace_daemon_id
    ) || {:error, :workspace_required}
  end

  defp refresh_task(%Task{user_id: user_id, project_id: project_id, id: task_id} = task)
       when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) do
    case Repo.get_by(Task, id: task_id, user_id: user_id, project_id: project_id) do
      %Task{} = fresh -> Task.with_legacy_worktree(fresh)
      nil -> task
    end
  end

  defp refresh_task(task), do: task

  defp maybe_place_child(%Task{id: task_id} = task, %Task{id: task_id}, _root_daemon),
    do: {:ok, task}

  defp maybe_place_child(%Task{} = task, _root_task, root_daemon) do
    if is_binary(Task.workspace_daemon(task)) do
      {:ok, task}
    else
      task
      |> Task.update_changeset(%{
        workspace: %{
          daemon_id: root_daemon,
          worktree_path: Task.workspace_worktree(task)
        }
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Task.with_legacy_worktree(updated)}
        {:error, _changeset} -> {:error, :child_placement_rejected}
      end
    end
  end

  defp fetch_task_by_id(task_id, user_id, project_id) do
    case Repo.get_by(Task, id: task_id, user_id: user_id, project_id: project_id) do
      %Task{} = task -> {:ok, Task.with_legacy_worktree(task)}
      nil -> {:error, :root_task_not_found}
    end
  end

  defp validate_child_daemon(%Task{id: task_id}, %Task{id: task_id}, _root_daemon), do: :ok

  defp validate_child_daemon(%Task{} = task, _root_task, root_daemon) do
    case Task.workspace_daemon(task) do
      nil -> :ok
      ^root_daemon -> :ok
      child_daemon -> {:error, {:child_daemon_conflict, child_daemon, root_daemon}}
    end
  end

  defp daemon_max_concurrency(daemon_id) do
    case Repo.get(Daemon, daemon_id) do
      %Daemon{max_concurrency: max_concurrency} -> max_concurrency
      _ -> nil
    end
  end
end
