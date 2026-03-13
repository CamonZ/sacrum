defmodule Sacrum.Repo.Broadcaster do
  @moduledoc """
  Shared broadcast logic for all repo modules.

  Provides a single entry point for broadcasting entity changes to the ProjectChannel.
  Handles different preload paths (direct :project vs nested workflow: :project).
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project

  # Dispatch map for dynamic function calls to ProjectChannel
  @channel_broadcasts %{
    task_created: :broadcast_task_created,
    task_updated: :broadcast_task_updated,
    task_deleted: :broadcast_task_deleted,
    workflow_created: :broadcast_workflow_created,
    workflow_updated: :broadcast_workflow_updated,
    workflow_deleted: :broadcast_workflow_deleted,
    step_created: :broadcast_step_created,
    step_updated: :broadcast_step_updated,
    step_deleted: :broadcast_step_deleted,
    step_transition_created: :broadcast_step_transition_created,
    step_transition_deleted: :broadcast_step_transition_deleted,
    step_execution_created: :broadcast_step_execution_created,
    step_execution_status_changed: :broadcast_step_execution_status_changed,
    session_log_created: :broadcast_session_log_created,
    section_created: :broadcast_section_created,
    section_updated: :broadcast_section_updated,
    section_deleted: :broadcast_section_deleted,
    run_step: :broadcast_run_step,
    cancel_step: :broadcast_cancel_step
  }

  @doc """
  Broadcast a result tuple from a repo operation.

  Handles {:ok, entity} by preloading and broadcasting, and passes through {:error, reason}.

  Args:
    - result: {:ok, entity} or {:error, reason}
    - event: event name (atom, e.g. :task_created)
    - preload_path: preload path (atom or list, e.g. :project or [workflow: :project])

  Returns:
    - {:ok, entity} on success
    - {:error, reason} on error
  """
  @spec broadcast({:ok, struct()} | {:error, term()}, atom(), atom() | keyword()) ::
          {:ok, struct()} | {:error, term()}
  def broadcast({:ok, entity}, event, preload_path) do
    broadcast_event(entity, event, preload_path)
    {:ok, entity}
  end

  def broadcast({:error, _} = error, _event, _preload_path), do: error

  @doc """
  Broadcast an entity directly after a successful operation.

  Preloads the entity with the specified path, extracts project ID, and calls
  the appropriate ProjectChannel function.

  Args:
    - entity: the entity to broadcast
    - event: event name (atom)
    - preload_path: preload path (atom or list)

  Returns:
    - :ok
  """
  @spec broadcast_event(struct(), atom(), atom() | keyword()) :: :ok
  def broadcast_event(entity, event, preload_path) do
    case extract_project_id(entity, preload_path) do
      {:ok, project_id} ->
        require Logger
        Logger.info("[Broadcast] #{event} for project #{project_id}")
        channel_func = Map.fetch!(@channel_broadcasts, event)
        apply(SacrumWeb.ProjectChannel, channel_func, [project_id, entity])

      :error ->
        require Logger
        Logger.warning("[Broadcast] #{event} failed to extract project_id")
        :ok
    end
  end

  # Extract project ID from an entity, handling different preload paths
  defp extract_project_id(entity, preload_path) do
    entity = Repo.preload(entity, preload_path)

    case get_project(entity, preload_path) do
      %Project{id: id} -> {:ok, id}
      _ -> :error
    end
  end

  # Direct project association (tasks, workflows)
  defp get_project(%{project: project}, :project), do: project

  # Nested workflow: :project (workflow_steps)
  defp get_project(%{workflow: %{project: project}}, workflow: :project), do: project

  # Nested from_step: [workflow: :project] (step_transitions)
  defp get_project(%{from_step: %{workflow: %{project: project}}},
         from_step: [workflow: :project]
       ),
       do: project

  # Special case for different structures - try to match the pattern
  defp get_project(entity, workflow: :project) do
    case Map.fetch(entity, :workflow) do
      {:ok, %{project: project}} -> project
      _ -> nil
    end
  end

  defp get_project(entity, from_step: [workflow: :project]) do
    case Map.fetch(entity, :from_step) do
      {:ok, %{workflow: %{project: project}}} -> project
      _ -> nil
    end
  end

  defp get_project(entity, :project) do
    case Map.fetch(entity, :project) do
      {:ok, project} -> project
      _ -> nil
    end
  end

  defp get_project(_entity, _path), do: nil

  @doc """
  Broadcast a step execution by first looking up its task to get the project.

  This is a specialized helper for step executions which don't have direct project associations.

  Args:
    - result: {:ok, execution} or {:error, reason}
    - event: event name (atom, e.g. :step_execution_created)

  Returns:
    - {:ok, execution} on success
    - {:error, reason} on error
  """
  @spec broadcast_step_execution({:ok, struct()} | {:error, term()}, atom()) ::
          {:ok, struct()} | {:error, term()}
  def broadcast_step_execution({:ok, execution}, event) do
    broadcast_step_execution_event(execution, event)
    {:ok, execution}
  end

  def broadcast_step_execution({:error, _} = error, _event), do: error

  @doc """
  Broadcast a session log by looking up its step execution and task to get the project.

  This is a specialized helper for session logs which don't have direct project associations.

  Args:
    - result: {:ok, log} or {:error, reason}
    - event: event name (atom, e.g. :session_log_created)

  Returns:
    - {:ok, log} on success
    - {:error, reason} on error
  """
  @spec broadcast_session_log({:ok, struct()} | {:error, term()}, atom()) ::
          {:ok, struct()} | {:error, term()}
  def broadcast_session_log({:ok, log}, event) do
    broadcast_session_log_event(log, event)
    {:ok, log}
  end

  def broadcast_session_log({:error, _} = error, _event), do: error

  @doc """
  Broadcast a section by looking up its task to get the project.

  This is a specialized helper for sections which don't have direct project associations.

  Args:
    - result: {:ok, section} or {:error, reason}
    - event: event name (atom, e.g. :section_created)

  Returns:
    - {:ok, section} on success
    - {:error, reason} on error
  """
  @spec broadcast_section({:ok, struct()} | {:error, term()}, atom()) ::
          {:ok, struct()} | {:error, term()}
  def broadcast_section({:ok, section}, event) do
    broadcast_section_event(section, event)
    {:ok, section}
  end

  def broadcast_section({:error, _} = error, _event), do: error

  # Private helper for step execution broadcast
  defp broadcast_step_execution_event(execution, event) do
    require Logger
    task = Repo.get(Sacrum.Repo.Schemas.Task, execution.task_id)

    if task do
      task = Repo.preload(task, :project)

      case task.project do
        %Project{id: project_id} ->
          Logger.info("[Broadcast] #{event} for project #{project_id}")
          channel_func = Map.fetch!(@channel_broadcasts, event)
          apply(SacrumWeb.ProjectChannel, channel_func, [project_id, execution])

        _ ->
          Logger.warning("[Broadcast] #{event} failed to extract project_id")
          :ok
      end
    end
  end

  # Private helper for session log broadcast
  defp broadcast_session_log_event(log, event) do
    require Logger
    log = Repo.preload(log, :step_execution)

    with %{step_execution: %{task_id: task_id}} when not is_nil(task_id) <- log,
         task when not is_nil(task) <- Repo.get(Sacrum.Repo.Schemas.Task, task_id),
         %{project: %Project{id: project_id}} <- Repo.preload(task, :project) do
      Logger.info("[Broadcast] #{event} for project #{project_id}")
      channel_func = Map.fetch!(@channel_broadcasts, event)
      apply(SacrumWeb.ProjectChannel, channel_func, [project_id, log])
    else
      _ ->
        Logger.warning("[Broadcast] #{event} failed to extract project_id")
        :ok
    end
  end

  # Private helper for section broadcast
  defp broadcast_section_event(section, event) do
    require Logger
    task = Repo.get(Sacrum.Repo.Schemas.Task, section.task_id)

    if task do
      task = Repo.preload(task, :project)

      case task.project do
        %Project{id: project_id} ->
          Logger.info("[Broadcast] #{event} for project #{project_id}")
          channel_func = Map.fetch!(@channel_broadcasts, event)
          apply(SacrumWeb.ProjectChannel, channel_func, [project_id, section])

        _ ->
          Logger.warning("[Broadcast] #{event} failed to extract project_id")
          :ok
      end
    end
  end

  @doc """
  Broadcast a run_step event with step execution and step definition data.

  Takes a step execution, its corresponding workflow step definition, workflow, transitions, and project ID,
  then constructs the combined payload and broadcasts to the daemon.

  Args:
    - execution: the StepExecution to broadcast
    - step: the WorkflowStep definition
    - workflow: the Workflow that contains the step
    - transitions: list of StepTransitions from the current step
    - project_id: the project ID to broadcast to

  Returns:
    - :ok
  """
  @spec broadcast_run_step(struct(), struct(), struct(), list(), String.t()) :: :ok
  def broadcast_run_step(execution, step, workflow, transitions, project_id) do
    require Logger
    Logger.info("[Broadcast] run_step for project #{project_id}")
    data = %{execution: execution, step: step, workflow: workflow, transitions: transitions}
    SacrumWeb.ProjectChannel.broadcast_run_step(project_id, data)
  end

  @doc """
  Broadcast a cancel_step event with step execution and task information.

  Takes a step execution and project ID, then constructs the payload and broadcasts.

  Args:
    - execution: the StepExecution to cancel
    - project_id: the project ID to broadcast to

  Returns:
    - :ok
  """
  @spec broadcast_cancel_step(struct(), String.t()) :: :ok
  def broadcast_cancel_step(execution, project_id) do
    require Logger
    Logger.info("[Broadcast] cancel_step for project #{project_id}")
    data = %{step_execution_id: execution.id, task_id: execution.task_id}
    SacrumWeb.ProjectChannel.broadcast_cancel_step(project_id, data)
  end
end
