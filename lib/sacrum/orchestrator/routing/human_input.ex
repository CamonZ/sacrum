defmodule Sacrum.Orchestrator.Routing.HumanInput do
  @moduledoc """
  Handles generic human-response workflow steps.

  A `human_input` step parks the active TaskRun with a waiting StepExecution
  whose config holds the step config with its `question` rendered. The
  response is supplied later through `resume/3`, or by attaching the config's
  `artifact` to that StepExecution (`complete_from_artifact/3`), validated
  against that config's `output_schema`, stored on that StepExecution, and then
  the same TaskRun is scheduled to continue through the normal workflow
  transition path.
  """

  import Ecto.Query

  require Logger

  alias Sacrum.Accounts

  alias Sacrum.Orchestrator.{
    ExecutionConfig,
    ExecutionHistory,
    ExecutionPool,
    FSMData,
    OutputValidator,
    PromptContext,
    PromptRenderer,
    Scheduler
  }

  alias Sacrum.Orchestrator.Routing.HumanInput.Draft
  alias Sacrum.Orchestrator.TaskRuns.{Lookup, StateTransitions}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ArtifactLink, StepExecution, Task, TaskRun, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Tasks.Status

  @type resume_result :: {:ok, StepExecution.t()} | {:error, term()}

  @spec handle_entry(FSMData.t(), Task.t(), WorkflowStep.t()) ::
          {:parked, FSMData.t()} | {:error, FSMData.t()}
  def handle_entry(%FSMData{} = data, %Task{} = task, %WorkflowStep{} = step) do
    task_id = task.id
    step = Repo.preload(step, :workflow)

    with {:ok, task_run} <-
           Lookup.fetch_for_task(data.user_id, data.project_id, task.id, data.task_run_id),
         {:ok, config} <- render_config(data, task, step, task_run),
         {:ok, %{execution: execution}} <- enter_waiting_state(data, task, step, task_run, config) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Entered human_input step=#{step.id} execution=#{execution.id}"
      )

      ExecutionPool.release_slot(data.slot_id)

      {:parked,
       %{
         data
         | current_execution_id: execution.id,
           slot_id: nil,
           pending_handoff: nil,
           pending_session: nil
       }}
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
    with {:ok, %{execution: completed, task_run: task_run}} <-
           complete(user_id, execution_id, output),
         :ok <- schedule_resumed_run(completed.task_id, task_run.id) do
      {:ok, completed}
    end
  end

  @doc """
  Resolves a gate from an artifact link inserted in the caller's transaction.

  A link resolves a gate when it targets a human_input StepExecution under the
  logical name that execution's config names as its `artifact`. The body is
  decoded as JSON and completes the execution as `resume/3` would, without
  scheduling: the caller schedules with `schedule_resumed_run/2` after commit.
  Returns `{:ok, nil}` for links that do not target a gate.
  """
  @spec complete_from_artifact(binary(), ArtifactLink.t(), String.t()) ::
          {:ok, %{execution: StepExecution.t(), task_run: TaskRun.t()} | nil}
          | {:error, term()}
  def complete_from_artifact(
        user_id,
        %ArtifactLink{subject_type: "step_execution", logical_name: logical_name} = link,
        body
      )
      when is_binary(user_id) and is_binary(logical_name) and is_binary(body) do
    case fetch_locked_gate_execution(user_id, link) do
      nil ->
        {:ok, nil}

      execution ->
        with :ok <- ensure_awaiting_response(execution),
             {:ok, output} <- decode_artifact_body(body) do
          complete(user_id, execution.id, output)
        end
    end
  end

  def complete_from_artifact(_user_id, %ArtifactLink{}, _body), do: {:ok, nil}

  @doc """
  Starts the TaskRun a completed human_input execution queued.
  """
  @spec schedule_resumed_run(binary(), binary()) :: :ok | {:error, term()}
  def schedule_resumed_run(task_id, task_run_id) do
    case Scheduler.schedule_task_run(task_id, task_run_id) do
      :ok -> :ok
      {:error, :orchestrator_already_running} -> :ok
      {:error, reason} -> {:error, {:resume_schedule_failed, reason, task_run_id}}
    end
  end

  # Validates the response and completes the waiting execution, queueing its
  # TaskRun. Joins the caller's transaction when there is one.
  @spec complete(binary(), binary(), term()) ::
          {:ok, %{execution: StepExecution.t(), task_run: TaskRun.t()}} | {:error, term()}
  defp complete(user_id, execution_id, output) do
    with {:ok, execution} <- fetch_resume_execution(user_id, execution_id),
         {:ok, output_schema} <- human_input_output_schema(execution),
         {:ok, encoded_output} <- validate_and_encode_output(output, output_schema) do
      Accounts.StepExecutions.complete_waiting_human_input(user_id, execution_id, encoded_output)
    end
  end

  # The gate's config is read from the execution, so a step edited after the
  # run parked does not change which artifact resolves it.
  @spec fetch_locked_gate_execution(binary(), ArtifactLink.t()) :: StepExecution.t() | nil
  defp fetch_locked_gate_execution(user_id, %ArtifactLink{} = link) do
    query =
      from(e in StepExecution,
        where:
          e.user_id == ^user_id and e.project_id == ^link.project_id and
            e.id == ^link.subject_id and e.step_type == ^:human_input,
        lock: "FOR UPDATE"
      )

    with %StepExecution{} = execution <- Repo.one(query),
         true <- WorkflowStep.config_value(execution, :artifact) == link.logical_name do
      lock_task_run(execution)
    else
      _not_a_gate -> nil
    end
  end

  @doc """
  Loads `execution`'s TaskRun with a row lock, so a stop or other transition
  cannot interleave with a resolution. Callers must already hold the
  execution lock: locks are always taken execution first, then run.
  """
  @spec lock_task_run(StepExecution.t()) :: StepExecution.t()
  def lock_task_run(%StepExecution{task_run_id: task_run_id} = execution) do
    task_run =
      Repo.one(from(r in TaskRun, where: r.id == ^task_run_id, lock: "FOR UPDATE"))

    %{execution | task_run: task_run}
  end

  @doc """
  Checks that the run is still parked on `execution` (its `task_run` loaded):
  a stopped run cancels it, and a completed one has already consumed a
  response.
  """
  @spec ensure_awaiting_response(StepExecution.t()) ::
          :ok | {:error, :human_input_execution_not_waiting}
  def ensure_awaiting_response(%StepExecution{
        id: id,
        status: "waiting",
        task_run: %TaskRun{status: :waiting, latest_step_execution_id: id}
      }),
      do: :ok

  def ensure_awaiting_response(%StepExecution{}),
    do: {:error, :human_input_execution_not_waiting}

  @spec decode_artifact_body(String.t()) :: {:ok, term()} | {:error, term()}
  defp decode_artifact_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_human_input_json, reason}}
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

  # The execution's own config is read, so editing the step does not change
  # what a parked gate accepts. A missing config means no schema.
  @spec human_input_output_schema(StepExecution.t()) :: {:ok, map() | nil} | {:error, term()}
  defp human_input_output_schema(
         %StepExecution{step: %WorkflowStep{step_type: :human_input}} = execution
       ),
       do: {:ok, WorkflowStep.output_schema(execution)}

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

  # Renders the step config with the same context as an llm_inference prompt,
  # plus the current-inclusive visit count of this step.
  @spec render_config(FSMData.t(), Task.t(), WorkflowStep.t(), TaskRun.t()) ::
          {:ok, Config.t()} | {:error, term()}
  defp render_config(data, task, step, task_run) do
    task = PromptRenderer.preload_for_rendering(task)

    execution = %StepExecution{
      task_id: task.id,
      task_run_id: task_run.id,
      step_id: step.id,
      step_name: step.name,
      step_type: step.step_type,
      handoff: data.pending_handoff
    }

    execution_data = ExecutionHistory.build_execution_data(task, execution, task_run)

    context =
      task
      |> PromptContext.build_context(execution_data, step, task_run)
      |> put_in(["execution", "step_visit_count"], visit_count(task, step))

    with {:error, reason} <- ExecutionConfig.render(step, context) do
      {:error, {:config_render_failed, reason}}
    end
  end

  # Completed visits of this step by the task, plus the one being entered.
  @spec visit_count(Task.t(), WorkflowStep.t()) :: pos_integer()
  defp visit_count(task, step) do
    completed =
      Repo.one(
        from(e in StepExecution,
          where:
            e.user_id == ^task.user_id and e.project_id == ^task.project_id and
              e.task_id == ^task.id and e.step_id == ^step.id and e.status == "completed",
          select: count(e.id)
        )
      )

    completed + 1
  end

  @spec enter_waiting_state(
          FSMData.t(),
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          Config.t()
        ) ::
          {:ok, map()} | {:error, term()}
  defp enter_waiting_state(data, task, step, task_run, config) do
    Repo.transaction(fn -> commit_waiting_state(data, task, step, task_run, config) end)
  end

  @spec commit_waiting_state(
          FSMData.t(),
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t(),
          Config.t()
        ) :: map()
  defp commit_waiting_state(data, task, step, task_run, config) do
    with {:ok, execution} <-
           data
           |> waiting_execution_changeset(task, step, task_run)
           |> StepExecution.put_config(config)
           |> put_seeded_draft(config, task_run, step)
           |> Repo.insert(),
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

  # A loop-back starts from the previous attempt's response, so the user
  # revises it instead of starting over.
  @spec put_seeded_draft(Ecto.Changeset.t(), Config.t(), TaskRun.t(), WorkflowStep.t()) ::
          Ecto.Changeset.t()
  defp put_seeded_draft(changeset, config, task_run, step) do
    previous_output =
      Repo.one(
        from(e in StepExecution,
          where:
            e.task_run_id == ^task_run.id and e.step_id == ^step.id and e.status == "completed",
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: 1,
          select: e.output
        )
      )

    case Draft.seed(config, previous_output) do
      draft when map_size(draft) == 0 -> changeset
      draft -> StepExecution.put_draft(changeset, draft)
    end
  end

  @spec waiting_execution_changeset(
          FSMData.t(),
          Task.t(),
          WorkflowStep.t(),
          TaskRun.t()
        ) :: Ecto.Changeset.t()
  defp waiting_execution_changeset(data, task, step, task_run) do
    attrs =
      maybe_put_handoff(
        %{
          task_id: task.id,
          task_run_id: task_run.id,
          workflow_id: task.workflow_id,
          step_id: step.id,
          step_name: step.name,
          step_type: step.step_type,
          status: "waiting"
        },
        data.pending_handoff
      )

    StepExecution.create_changeset(
      %StepExecution{user_id: data.user_id, project_id: data.project_id},
      attrs
    )
  end

  defp maybe_put_handoff(attrs, handoff) when is_map(handoff),
    do: Map.put(attrs, :handoff, handoff)

  defp maybe_put_handoff(attrs, _handoff), do: attrs
end
