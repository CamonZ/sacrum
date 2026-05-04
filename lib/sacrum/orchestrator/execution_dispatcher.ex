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
  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionHistory, PromptContext, PromptRenderer, TaskRunLifecycle}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus
  alias Sacrum.Tasks.Status

  defguardp task_run_lookup_error(reason)
            when reason in [
                   :task_run_not_found,
                   :task_run_user_mismatch,
                   :task_run_project_mismatch,
                   :task_run_task_mismatch
                 ]

  @doc """
  Creates a "started" StepExecution for the current step and broadcasts run_step
  to the daemon. The dispatcher is the single source of execution row creation
  for execute/route/evaluate steps.

  `handoff` is attached to the new row when present (typically supplied by the
  orchestrator from FSMData after a route step).
  """
  @spec create_and_dispatch(
          String.t(),
          struct(),
          String.t(),
          String.t() | TaskRun.t(),
          map() | nil
        ) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id, task_run_or_id, handoff \\ nil) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         :ok <- validate_workflow(task),
         {:ok, task_run} <- fetch_and_validate_task_run(task_run_or_id, task),
         {:ok, %{execution: execution, task: task, task_run: updated_task_run}} <-
           insert_and_stamp(task, step, task_run, handoff) do
      execution_data = ExecutionHistory.build_execution_data(task.id, execution)
      context = PromptContext.build_context(task, execution_data, step)

      render_and_broadcast(task, step, execution, context, updated_task_run)
    else
      {:error, _op, reason, _changes} ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        mark_dispatch_failure(task_run_or_id, reason)
        {:error, reason}

      {:error, reason} = err ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        mark_dispatch_failure(task_run_or_id, reason)
        err
    end
  end

  defp fetch_step(user_id, step_id) do
    Accounts.WorkflowSteps.get_by(user_id,
      conditions: [id: step_id],
      preloads: [:workflow]
    )
  end

  defp validate_workflow(%{workflow_id: nil}), do: {:error, :no_workflow}
  defp validate_workflow(_task), do: :ok

  # Inserts the started StepExecution, advances the TaskRun cursor/status, and
  # updates task timestamps/derived status in one transaction. The task changeset
  # is built after the execution insert so derive/1 sees the new execution.
  defp insert_and_stamp(task, step, task_run, handoff) do
    Multi.new()
    |> Multi.insert(:execution, started_execution_changeset(task, step, task_run, handoff))
    |> Multi.update(:task_run, fn %{execution: execution} ->
      TaskRun.update_changeset(task_run, %{
        status: :executing,
        latest_step_execution_id: execution.id
      })
    end)
    |> Multi.update(:task, fn _changes -> task_dispatch_changeset(task) end)
    |> Repo.transaction()
  end

  defp started_execution_changeset(task, step, task_run, handoff) do
    attrs = %{
      task_id: task.id,
      task_run_id: task_run.id,
      workflow_id: task.workflow_id,
      step_id: step.id,
      step_name: step.name,
      status: "started"
    }

    attrs = if is_map(handoff), do: Map.put(attrs, :handoff, handoff), else: attrs

    StepExecution.create_changeset(
      %StepExecution{user_id: task.user_id, project_id: task.project_id},
      attrs
    )
  end

  defp task_dispatch_changeset(task) do
    changes = if is_nil(task.started_at), do: %{started_at: DateTime.utc_now()}, else: %{}

    task
    |> Ecto.Changeset.change(changes)
    |> Status.put_status()
  end

  defp fetch_and_validate_task_run(%TaskRun{} = task_run, task) do
    validate_task_run(task_run, task)
  end

  defp fetch_and_validate_task_run(task_run_id, task) when is_binary(task_run_id) do
    case Repo.get(TaskRun, task_run_id) do
      nil -> {:error, :task_run_not_found}
      task_run -> validate_task_run(task_run, task)
    end
  end

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

  defp render_and_broadcast(task, step, execution, context, task_run) do
    with {:ok, rendered} <- PromptRenderer.render(step.prompt, context),
         {:ok, updated_execution} <-
           Accounts.StepExecutions.update(execution, %{prompt: rendered}) do
      Logger.info(
        "[ExecutionDispatcher] Dispatching execution=#{updated_execution.id} step=#{step.name} " <>
          "task=#{task.id} task_run=#{task_run.id} prompt_length=#{String.length(rendered)}"
      )

      Broadcaster.broadcast_run_step(
        %{execution: updated_execution, step: step, task: task, rendered_prompt: rendered},
        task.project_id
      )

      Broadcaster.broadcast_step_execution({:ok, updated_execution}, :step_execution_created)

      {:ok, updated_execution}
    else
      {:error, reason} = error ->
        mark_execution_failed(execution, reason)

        TaskRunLifecycle.mark_failed(task_run, {:dispatch_failed, reason}, %{
          execution_id: execution.id
        })

        error
    end
  end

  defp mark_execution_failed(execution, reason) do
    execution
    |> StepExecution.update_changeset(%{
      status: "failed",
      output: "Dispatch failed before daemon execution: #{inspect(reason)}"
    })
    |> Repo.update()
  end

  defp mark_dispatch_failure(_task_run_or_id, reason)
       when task_run_lookup_error(reason),
       do: :ok

  defp mark_dispatch_failure(_task_run_or_id, {:task_run_not_dispatchable, _status}), do: :ok

  defp mark_dispatch_failure(task_run_or_id, reason) do
    case fetch_task_run_for_failure(task_run_or_id) do
      {:ok, task_run} ->
        TaskRunLifecycle.mark_failed_if_active(task_run, {:dispatch_failed, reason})

      {:error, _reason} ->
        :ok
    end
  end

  defp fetch_task_run_for_failure(%TaskRun{} = task_run), do: {:ok, task_run}

  defp fetch_task_run_for_failure(task_run_id) when is_binary(task_run_id) do
    case Repo.get(TaskRun, task_run_id) do
      nil -> {:error, :not_found}
      task_run -> {:ok, task_run}
    end
  end

  defp fetch_task_run_for_failure(_task_run), do: {:error, :invalid_task_run}
end
