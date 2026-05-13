defmodule Sacrum.Accounts.StepExecutions do
  @moduledoc """
  User-scoped step execution operations.

  All operations are scoped to a specific user.
  """

  import Ecto.Query

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.StepExecutions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Orchestrator.ExecutionEvents
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun, WorkflowStep}

  defguardp human_input_resume_args(user_id, execution_id, encoded_output)
            when is_binary(user_id) and is_binary(execution_id) and is_binary(encoded_output)

  @doc """
  Insert a new step execution for a user.
  Extracts task_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) :: {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %StepExecution{user_id: user_id, task_id: task_id, project_id: project_id}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an existing step execution.
  """
  @spec update(StepExecution.t(), map()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()}
  def update(%StepExecution{} = execution, attrs) do
    require Logger

    Logger.info(
      "[StepExecutions.update] exec=#{execution.id} current_status=#{execution.status} new_attrs=#{inspect(Map.keys(attrs))}"
    )

    result =
      with :ok <- prevent_human_input_resume_bypass(execution, attrs) do
        execution
        |> StepExecution.update_changeset(attrs)
        |> Repo.update()
      end

    case result do
      {:ok, updated} ->
        if updated.status != execution.status do
          ExecutionEvents.broadcast_status_changed(updated)
        end

        Logger.info(
          "[StepExecutions.update] Success: exec=#{updated.id} new_status=#{updated.status}"
        )

        {:ok, updated}

      {:error, reason} ->
        Logger.error("[StepExecutions.update] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Complete a waiting human_input execution through the server-owned resume path.

  The execution row is locked before checking status, so only one waiting
  human_input response can be consumed. If a previous resume completed the
  execution but scheduling failed, retrying with the same canonical output
  returns the completed execution while the same TaskRun remains queued.
  """
  @spec complete_waiting_human_input(String.t(), String.t(), String.t()) ::
          {:ok, %{execution: StepExecution.t(), task_run: TaskRun.t()}} | {:error, term()}
  def complete_waiting_human_input(user_id, execution_id, encoded_output)
      when human_input_resume_args(user_id, execution_id, encoded_output) do
    result =
      Repo.transaction(fn ->
        with {:ok, execution} <- fetch_locked_for_human_input_completion(user_id, execution_id),
             {:ok, changes} <- complete_locked_human_input(execution, encoded_output) do
          changes
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    result
  end

  @spec prevent_human_input_resume_bypass(StepExecution.t(), map()) ::
          :ok | {:error, Ecto.Changeset.t()}
  defp prevent_human_input_resume_bypass(%StepExecution{status: "waiting"} = execution, attrs) do
    if protected_human_input_update?(execution, attrs) and human_input_execution?(execution) do
      {:error, human_input_bypass_changeset(execution)}
    else
      :ok
    end
  end

  defp prevent_human_input_resume_bypass(%StepExecution{}, _attrs), do: :ok

  @spec human_input_execution?(StepExecution.t()) :: boolean()
  defp human_input_execution?(%StepExecution{step_id: nil}), do: false

  defp human_input_execution?(%StepExecution{step: %WorkflowStep{step_type: "human_input"}}),
    do: true

  defp human_input_execution?(%StepExecution{step_id: step_id}) do
    case Repo.get(WorkflowStep, step_id) do
      %WorkflowStep{step_type: "human_input"} -> true
      _ -> false
    end
  end

  @spec protected_human_input_update?(StepExecution.t(), map()) :: boolean()
  defp protected_human_input_update?(execution, attrs) do
    output_update?(attrs) or status_change?(execution, attrs)
  end

  defp output_update?(attrs), do: Map.has_key?(attrs, :output) or Map.has_key?(attrs, "output")

  defp status_change?(execution, attrs) do
    case Map.get(attrs, :status) || Map.get(attrs, "status") do
      nil -> false
      status -> status != execution.status
    end
  end

  defp human_input_bypass_changeset(execution) do
    execution
    |> StepExecution.update_changeset(%{})
    |> Ecto.Changeset.add_error(
      :status,
      "waiting human_input executions can only be completed by the human input resume operation"
    )
  end

  @spec fetch_locked_for_human_input_completion(String.t(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, :not_found}
  defp fetch_locked_for_human_input_completion(user_id, execution_id) do
    case Repo.one(
           from(e in StepExecution,
             where: e.user_id == ^user_id and e.id == ^execution_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :not_found}
      execution -> {:ok, Repo.preload(execution, [:step, :task_run])}
    end
  end

  @spec complete_locked_human_input(StepExecution.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defp complete_locked_human_input(%StepExecution{} = execution, encoded_output) do
    with :ok <- validate_human_input_completion_target(execution) do
      consume_or_retry_completed_human_input(execution, encoded_output)
    end
  end

  @spec validate_human_input_completion_target(StepExecution.t()) :: :ok | {:error, term()}
  defp validate_human_input_completion_target(%StepExecution{task_run_id: nil}),
    do: {:error, :human_input_execution_missing_task_run}

  defp validate_human_input_completion_target(%StepExecution{
         step: %WorkflowStep{step_type: "human_input"}
       }),
       do: :ok

  defp validate_human_input_completion_target(%StepExecution{}),
    do: {:error, :not_human_input_execution}

  @spec consume_or_retry_completed_human_input(StepExecution.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  defp consume_or_retry_completed_human_input(
         %StepExecution{status: "waiting"} = execution,
         encoded_output
       ) do
    with {:ok, completed} <- complete_human_input_execution(execution, encoded_output),
         {:ok, task_run} <- queue_human_input_task_run(completed) do
      {:ok, %{execution: completed, task_run: task_run}}
    end
  end

  defp consume_or_retry_completed_human_input(
         %StepExecution{
           id: id,
           status: "completed",
           output: output,
           task_run: %TaskRun{status: :queued, latest_step_execution_id: id} = task_run
         } = execution,
         output
       ) do
    {:ok, %{execution: execution, task_run: task_run}}
  end

  defp consume_or_retry_completed_human_input(%StepExecution{}, _encoded_output),
    do: {:error, :human_input_execution_not_waiting}

  @spec complete_human_input_execution(StepExecution.t(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()}
  defp complete_human_input_execution(%StepExecution{} = execution, encoded_output) do
    execution
    |> StepExecution.update_changeset(%{status: "completed", output: encoded_output})
    |> Repo.update()
  end

  @spec queue_human_input_task_run(StepExecution.t()) ::
          {:ok, TaskRun.t()}
          | {:error, Ecto.Changeset.t() | :human_input_execution_missing_task_run}
  defp queue_human_input_task_run(%StepExecution{task_run: %TaskRun{} = task_run} = execution) do
    task_run
    |> TaskRun.update_changeset(%{
      status: :queued,
      latest_step_execution_id: execution.id
    })
    |> Repo.update()
  end

  defp queue_human_input_task_run(%StepExecution{}),
    do: {:error, :human_input_execution_missing_task_run}
end
