defmodule Sacrum.Orchestrator.Routing.HumanInput do
  @moduledoc """
  Handles generic human-response workflow steps.

  A `human_input` step parks the active TaskRun with a waiting StepExecution.
  The response is supplied later through `resume/3`, validated against the
  step output schema, stored on that StepExecution, and then the same TaskRun is
  scheduled to continue through the normal workflow transition path.
  """

  require Logger

  alias Sacrum.Accounts

  alias Sacrum.Orchestrator.{
    ExecutionHistory,
    ExecutionPool,
    FSMData,
    OutputValidator,
    PromptContext,
    PromptRenderer,
    Scheduler
  }

  alias Sacrum.Orchestrator.TaskRuns.{Lookup, StateTransitions}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun, WorkflowStep}
  alias Sacrum.Tasks.Status

  @type resume_result :: {:ok, StepExecution.t()} | {:error, term()}

  @spec handle_entry(FSMData.t(), Task.t(), WorkflowStep.t()) ::
          {:parked, FSMData.t()} | {:error, FSMData.t()}
  def handle_entry(%FSMData{} = data, %Task{} = task, %WorkflowStep{} = step) do
    task_id = task.id
    step = Repo.preload(step, :workflow)

    with {:ok, task_run} <- Lookup.fetch(data.task_run_id),
         {:ok, rendered_prompt} <-
           render_human_prompt(task, step, task_run, data.pending_handoff),
         {:ok, %{execution: execution}} <-
           enter_waiting_state(data, task, step, task_run, rendered_prompt) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Entered human_input step=#{step.id} execution=#{execution.id}"
      )

      ExecutionPool.release_slot(data.slot_id)
      {:parked, %{data | current_execution_id: execution.id, slot_id: nil, pending_handoff: nil}}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to enter human_input: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:error, %{data | slot_id: nil}}
    end
  end

  @spec resume(binary(), binary(), term()) :: resume_result()
  def resume(user_id, execution_id, output)
      when is_binary(user_id) and is_binary(execution_id) do
    with {:ok, execution} <- fetch_resume_execution(user_id, execution_id),
         {:ok, output_schema} <- human_input_output_schema(execution),
         {:ok, encoded_output} <-
           validate_and_encode_output(output, output_schema),
         {:ok, %{execution: completed, task_run: task_run}} <-
           Accounts.StepExecutions.complete_waiting_human_input(
             user_id,
             execution_id,
             encoded_output
           ),
         :ok <- schedule_resumed_run(completed.task_id, task_run.id) do
      {:ok, completed}
    end
  end

  @spec canonical_json(term()) :: {:ok, String.t()} | {:error, term()}
  defp canonical_json(output) do
    case Jason.encode(output) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:invalid_json_compatible_output, reason}}
    end
  end

  @spec decode_json_output(String.t()) :: {:ok, term()} | {:error, term()}
  defp decode_json_output(encoded) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json_compatible_output, reason}}
    end
  end

  @spec fetch_resume_execution(binary(), binary()) ::
          {:ok, StepExecution.t()} | {:error, :not_found}
  defp fetch_resume_execution(user_id, execution_id) do
    Accounts.StepExecutions.get_by(user_id,
      conditions: [id: execution_id],
      preloads: [:step]
    )
  end

  @spec human_input_output_schema(StepExecution.t()) :: {:ok, map() | nil} | {:error, term()}
  defp human_input_output_schema(%StepExecution{
         step: %WorkflowStep{step_type: "human_input", output_schema: output_schema}
       }),
       do: {:ok, output_schema}

  defp human_input_output_schema(%StepExecution{}), do: {:error, :not_human_input_execution}

  @spec validate_and_encode_output(term(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  defp validate_and_encode_output(output, output_schema) do
    with {:ok, encoded} <- canonical_json(output),
         {:ok, decoded} <- decode_json_output(encoded),
         :ok <- validate_normalized_output(decoded, output_schema) do
      {:ok, encoded}
    end
  end

  @spec validate_normalized_output(term(), map() | nil) :: :ok | {:error, term()}
  defp validate_normalized_output(output, output_schema) do
    case OutputValidator.validate_output(output, output_schema) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_human_input, reason}}
    end
  end

  @spec schedule_resumed_run(binary(), binary()) :: :ok | {:error, term()}
  defp schedule_resumed_run(task_id, task_run_id) do
    case Scheduler.schedule_task_run(task_id, task_run_id) do
      :ok -> :ok
      {:error, :orchestrator_already_running} -> :ok
      {:error, reason} -> {:error, {:resume_schedule_failed, reason, task_run_id}}
    end
  end

  @spec enter_waiting_state(
          FSMData.t(),
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  defp enter_waiting_state(data, task, step, task_run, rendered_prompt) do
    Repo.transaction(fn ->
      commit_waiting_state(data, task, step, task_run, rendered_prompt)
    end)
  end

  @spec commit_waiting_state(FSMData.t(), Task.t(), WorkflowStep.t(), TaskRun.t(), String.t()) ::
          map()
  defp commit_waiting_state(data, task, step, task_run, rendered_prompt) do
    with {:ok, execution} <-
           Repo.insert(waiting_execution_changeset(data, task, step, task_run, rendered_prompt)),
         {:ok, updated_task_run} <-
           task_run
           |> StateTransitions.waiting_changeset(execution.id)
           |> Repo.update(),
         {:ok, updated_task} <- Repo.update(Status.changeset(task)) do
      %{execution: execution, task_run: updated_task_run, task: updated_task}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec waiting_execution_changeset(
          FSMData.t(),
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          String.t()
        ) :: Ecto.Changeset.t()
  defp waiting_execution_changeset(data, task, step, task_run, rendered_prompt) do
    attrs =
      maybe_put_handoff(
        %{
          task_id: task.id,
          task_run_id: task_run.id,
          workflow_id: task.workflow_id,
          step_id: step.id,
          step_name: step.name,
          step_type: step.step_type,
          status: "waiting",
          prompt: rendered_prompt
        },
        data.pending_handoff
      )

    StepExecution.create_changeset(
      %StepExecution{user_id: data.user_id, project_id: data.project_id},
      attrs
    )
  end

  @spec render_human_prompt(Task.t(), WorkflowStep.t(), TaskRun.t(), map() | nil) ::
          {:ok, String.t()}
  defp render_human_prompt(task, step, task_run, handoff) do
    execution =
      %StepExecution{
        user_id: task.user_id,
        project_id: task.project_id,
        task_id: task.id,
        task_run_id: task_run.id,
        workflow_id: task.workflow_id,
        step_id: step.id,
        step_name: step.name,
        step_type: step.step_type,
        status: "waiting",
        handoff: handoff
      }

    execution_data = ExecutionHistory.build_execution_data(task.id, execution)
    context = PromptContext.build_context(task, execution_data, step)

    PromptRenderer.render(step.prompt, context)
  end

  defp maybe_put_handoff(attrs, handoff) when is_map(handoff),
    do: Map.put(attrs, :handoff, handoff)

  defp maybe_put_handoff(attrs, _handoff), do: attrs
end
