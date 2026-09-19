defmodule Sacrum.Orchestrator.ExecutionDispatcher do
  @moduledoc """
  Dispatches step executions to the daemon.

  Creates a StepExecution row in "started" status for the current step,
  renders the prompt using PromptRenderer with Liquid/Solid templates,
  and broadcasts a run_step event to the daemon.

  The dispatcher is the single source of StepExecution row creation for
  execute/evaluate/route steps. Transitions (advance_to_step, move_to_step)
  only update current_step_id; execution rows are created exclusively
  at dispatch time.

  Used by both the GraphQL runStep resolver and the TaskOrchestrator to
  ensure consistent execution dispatch behavior.
  """

  require Logger

  alias Ecto.Multi

  alias Sacrum.Orchestrator.{
    AsyncStepExecutionSupervisor,
    ExecutionHistory,
    PromptContext,
    PromptRenderer
  }

  alias Sacrum.Orchestrator.TaskRuns.Failure
  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun, WorkflowStep}
  alias Sacrum.Routing.RouteMode
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus
  alias Sacrum.Tasks.Status

  @typep handoff :: map() | nil

  @doc """
  Creates a "started" StepExecution for the current step and broadcasts run_step
  to the daemon. The dispatcher is the single source of execution row creation
  for execute/route/evaluate steps.

  `handoff` is attached to the new row when present (typically supplied by the
  orchestrator from FSMData after a route step).
  """
  @spec create_and_dispatch(
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          map() | nil,
          keyword()
        ) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(task, step, task_run, handoff \\ nil, opts \\ []) do
    with :ok <- validate_dispatch_context(task, step, task_run),
         :ok <- validate_dispatchable_step(step),
         :ok <- validate_workflow(task),
         {:ok, _task_run} <- validate_task_run(task_run, task) do
      case Keyword.get(opts, :reuse_active, false) &&
             reusable_active_execution(Keyword.get(opts, :active_execution), task_run, step) do
        %StepExecution{} = execution ->
          {:ok, execution}

        _ ->
          {:ok, rendered} = render_dispatch_prompt(task, step, task_run, handoff)
          commit_and_broadcast_dispatch(task, step, task_run, handoff, rendered)
      end
    else
      {:error, reason} = err ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        mark_dispatch_failure(task_run, reason)
        err
    end
  end

  @doc "Persists a queued direct run and starts its supervised asynchronous worker."
  @spec create_and_queue(Task.t(), WorkflowStep.t(), TaskRun.t(), keyword()) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_queue(task, step, task_run, admission_opts \\ []) do
    with :ok <- validate_dispatch_context(task, step, task_run),
         :ok <- validate_dispatchable_step(step),
         :ok <- validate_workflow(task),
         {:ok, _task_run} <- validate_task_run(task_run, task),
         {:ok, rendered} <- render_dispatch_prompt(task, step, task_run, nil),
         {:ok, %{execution: execution}} <-
           insert_and_stamp(task, step, task_run, nil, rendered, "queued"),
         {:ok, _pid} <-
           AsyncStepExecutionSupervisor.start_execution(
             execution.id,
             task.user_id,
             task.project_id,
             task_run.id,
             Sacrum.Orchestrator.ExecutionPool,
             admission_opts
           ) do
      {:ok, execution}
    else
      {:error, reason} = err ->
        Logger.error("[ExecutionDispatcher] create_and_queue failed: #{inspect(reason)}")
        mark_dispatch_failure(task_run, reason)
        err
    end
  end

  defp reusable_active_execution(
         %StepExecution{
           task_run_id: task_run_id,
           step_id: step_id,
           status: status
         } = execution,
         %TaskRun{id: task_run_id},
         %WorkflowStep{id: step_id}
       )
       when status in ["queued", "started", "in_progress"],
       do: execution

  defp reusable_active_execution(_execution, _task_run, _step), do: nil

  @doc """
  Validate that a workflow step may be dispatched directly by a client.

  Stop steps are orchestrator-owned run boundaries. They are reached through
  workflow transitions and are never dispatched to a daemon.
  """
  @spec validate_step(WorkflowStep.t()) :: :ok | {:error, term()}
  def validate_step(%WorkflowStep{} = step), do: validate_dispatchable_step(step)

  defp validate_dispatchable_step(%WorkflowStep{step_type: :stop}),
    do: {:error, :stop_step_not_dispatchable}

  defp validate_dispatchable_step(%WorkflowStep{step_type: :route, route_config: route_config})
       when not is_nil(route_config),
       do: {:error, :configured_route_not_dispatchable}

  defp validate_dispatchable_step(%WorkflowStep{step_type: :route} = step) do
    case RouteMode.routing_mode(step) do
      {:ok, {:legacy, _prompt}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_dispatchable_step(_step), do: :ok

  @spec validate_workflow(map()) :: :ok | {:error, :no_workflow}
  defp validate_workflow(%{workflow_id: nil}), do: {:error, :no_workflow}
  defp validate_workflow(_task), do: :ok

  @spec validate_dispatch_context(Task.t(), WorkflowStep.t(), TaskRun.t()) ::
          :ok | {:error, term()}
  defp validate_dispatch_context(
         %Task{} = task,
         %WorkflowStep{} = step,
         %TaskRun{} = task_run
       ) do
    cond do
      task.user_id != step.user_id -> {:error, :step_user_mismatch}
      task.user_id != task_run.user_id -> {:error, :task_run_user_mismatch}
      task.project_id != task_run.project_id -> {:error, :task_run_project_mismatch}
      task.id != task_run.task_id -> {:error, :task_run_task_mismatch}
      true -> :ok
    end
  end

  @spec render_dispatch_prompt(Task.t(), WorkflowStep.t(), TaskRun.t(), handoff()) ::
          {:ok, String.t()} | {:error, term()}
  defp render_dispatch_prompt(task, step, task_run, handoff) do
    execution = execution_struct(task, step, task_run, handoff, %{})
    execution_data = ExecutionHistory.build_execution_data(task, execution, task_run)
    context = PromptContext.build_context(task, execution_data, step, task_run)

    PromptRenderer.render(step.prompt, context)
  end

  @spec commit_and_broadcast_dispatch(
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          handoff(),
          String.t()
        ) ::
          {:ok, StepExecution.t()} | {:error, term()}
  defp commit_and_broadcast_dispatch(task, step, task_run, handoff, rendered) do
    case insert_and_stamp(task, step, task_run, handoff, rendered) do
      {:ok, %{execution: execution, task: task, task_run: updated_task_run}} ->
        broadcast_dispatch(task, step, execution, rendered, updated_task_run)

      {:error, _op, reason, _changes} ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        mark_dispatch_failure(task_run, reason)
        {:error, reason}
    end
  end

  # Inserts the started StepExecution with its rendered prompt, advances the
  # TaskRun cursor/status, and updates task timestamps/derived status in one
  # transaction. The task changeset is built after the execution insert so
  # derive/1 sees the new execution.
  @spec insert_and_stamp(Task.t(), WorkflowStep.t(), TaskRun.t(), handoff(), String.t()) ::
          {:ok, map()} | {:error, atom(), term(), map()}
  defp insert_and_stamp(task, step, task_run, handoff, rendered, status \\ "started") do
    Multi.new()
    |> Multi.insert(
      :execution,
      execution_changeset(task, step, task_run, handoff, %{prompt: rendered, status: status})
    )
    |> Multi.update(:task_run, fn %{execution: execution} ->
      TaskRun.update_changeset(task_run, %{
        status: :executing,
        latest_step_execution_id: execution.id
      })
    end)
    |> Multi.update(:task, fn _changes -> task_dispatch_changeset(task) end)
    |> Repo.transaction()
  end

  @spec execution_changeset(Task.t(), WorkflowStep.t(), TaskRun.t(), handoff(), map()) ::
          Ecto.Changeset.t()
  defp execution_changeset(task, step, task_run, handoff, overrides) do
    task
    |> execution_struct(step, task_run, handoff, overrides)
    |> StepExecution.create_changeset(execution_attrs(task, step, task_run, handoff, overrides))
  end

  @spec execution_struct(Task.t(), WorkflowStep.t(), TaskRun.t(), handoff(), map()) ::
          StepExecution.t()
  defp execution_struct(task, step, task_run, handoff, overrides) do
    attrs = execution_attrs(task, step, task_run, handoff, overrides)

    %StepExecution{
      user_id: task.user_id,
      project_id: task.project_id,
      task_id: task.id,
      task_run_id: task_run.id,
      workflow_id: task.workflow_id,
      step_id: step.id,
      step_name: step.name,
      step_type: step.step_type,
      status: attrs.status,
      handoff: attrs[:handoff],
      prompt: attrs[:prompt],
      output: attrs[:output]
    }
  end

  @spec execution_attrs(Task.t(), WorkflowStep.t(), TaskRun.t(), handoff(), map()) :: map()
  defp execution_attrs(task, step, task_run, handoff, overrides) do
    attrs =
      Map.merge(
        %{
          task_id: task.id,
          task_run_id: task_run.id,
          workflow_id: task.workflow_id,
          step_id: step.id,
          step_name: step.name,
          step_type: step.step_type,
          status: "started"
        },
        overrides
      )

    if is_map(handoff), do: Map.put(attrs, :handoff, handoff), else: attrs
  end

  @spec task_dispatch_changeset(Task.t()) :: Ecto.Changeset.t()
  defp task_dispatch_changeset(task) do
    changes = if is_nil(task.started_at), do: %{started_at: DateTime.utc_now()}, else: %{}

    task
    |> Ecto.Changeset.change(changes)
    |> Status.put_status()
  end

  @spec broadcast_dispatch(
          Task.t(),
          WorkflowStep.t(),
          StepExecution.t(),
          String.t(),
          TaskRun.t()
        ) ::
          {:ok, StepExecution.t()}
  defp broadcast_dispatch(task, step, execution, rendered, task_run) do
    Logger.info(
      "[ExecutionDispatcher] Dispatching execution=#{execution.id} step=#{step.name} " <>
        "task=#{task.id} task_run=#{task_run.id} prompt_length=#{String.length(rendered)}"
    )

    CommandBroadcaster.broadcast_run_step(
      %{execution: execution, step: step, task: task, rendered_prompt: rendered},
      task.project_id
    )

    {:ok, execution}
  end

  @spec validate_task_run(TaskRun.t(), Task.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp validate_task_run(%TaskRun{} = task_run, task) do
    cond do
      task_run.user_id != task.user_id ->
        {:error, :task_run_user_mismatch}

      task_run.project_id != task.project_id ->
        {:error, :task_run_project_mismatch}

      task_run.task_id != task.id ->
        {:error, :task_run_task_mismatch}

      not TaskRunStatus.stoppable?(task_run.status) ->
        {:error, {:task_run_not_dispatchable, task_run.status}}

      true ->
        {:ok, task_run}
    end
  end

  @spec mark_dispatch_failure(term(), term()) ::
          :ok | {:ok, TaskRun.t() | :unchanged} | {:error, term()}
  defp mark_dispatch_failure(_task_run, reason)
       when reason in [
              :step_user_mismatch,
              :task_run_user_mismatch,
              :task_run_project_mismatch,
              :task_run_task_mismatch
            ],
       do: :ok

  defp mark_dispatch_failure(_task_run_or_id, {:task_run_not_dispatchable, _status}), do: :ok

  defp mark_dispatch_failure(_task_run_or_id, :stop_step_not_dispatchable), do: :ok

  defp mark_dispatch_failure(_task_run_or_id, :configured_route_not_dispatchable), do: :ok

  defp mark_dispatch_failure(_task_run_or_id, :route_not_configured), do: :ok

  defp mark_dispatch_failure(%TaskRun{} = task_run, reason) do
    Failure.mark_if_active(task_run, {:dispatch_failed, reason})
  end
end
