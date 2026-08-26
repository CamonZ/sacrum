defmodule Sacrum.Orchestrator.OutputArtifact do
  @moduledoc """
  Persists configured structured step output as a task artifact.

  This is intentionally orchestrator-owned. The daemon only produces the
  structured output; it does not need to know where that output is stored.
  """

  import Ecto.Query

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Orchestrator.{FSMData, OutputValidator, PersistenceOptions, StructuredOutput}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @spec persist(FSMData.t(), WorkflowStep.t()) ::
          :ok | {:error, term()}
  def persist(%FSMData{} = data, %WorkflowStep{} = step) do
    case PersistenceOptions.artifact_logical_name(step.persistence_options) do
      nil ->
        :ok

      logical_name ->
        with {:ok, execution} <- fetch_completed_execution(data, step) do
          persist_artifact(data, step, execution, logical_name)
        end
    end
  end

  @spec persist(FSMData.t(), WorkflowStep.t(), binary() | StepExecution.t()) ::
          :ok | {:error, term()}
  def persist(%FSMData{} = data, %WorkflowStep{} = step, %StepExecution{} = execution) do
    case PersistenceOptions.artifact_logical_name(step.persistence_options) do
      nil -> :ok
      logical_name -> persist_artifact(data, step, execution, logical_name)
    end
  end

  def persist(%FSMData{} = data, %WorkflowStep{} = step, execution_id)
      when is_binary(execution_id) do
    case PersistenceOptions.artifact_logical_name(step.persistence_options) do
      nil ->
        :ok

      logical_name ->
        with {:ok, execution} <- fetch_completed_execution(data, step, execution_id) do
          persist_artifact(data, step, execution, logical_name)
        end
    end
  end

  defp persist_artifact(data, step, execution, logical_name) do
    with :ok <- require_output_schema(step.output_schema),
         {:ok, decoded_output} <- decode_output(execution.output),
         :ok <- OutputValidator.validate_output(decoded_output, step.output_schema),
         {:ok, body} <- Jason.encode(decoded_output) do
      upsert_task_artifact(data, logical_name, body)
    end
  end

  defp upsert_task_artifact(data, logical_name, body) do
    artifact_attrs = %{filename: "#{logical_name}.json", body: body}

    case Artifacts.get_for_subject_by_logical_name(
           data.user_id,
           data.project_id,
           "task",
           data.task.id,
           logical_name
         ) do
      {:ok, artifact} ->
        case Artifacts.update(data.user_id, artifact.id, artifact_attrs) do
          {:ok, _updated_artifact} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        case Artifacts.create_and_link(
               data.user_id,
               data.project_id,
               artifact_attrs,
               %{subject_type: "task", subject_id: data.task.id, logical_name: logical_name}
             ) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp fetch_completed_execution(data, step) do
    case data.current_execution_id do
      execution_id when is_binary(execution_id) ->
        fetch_completed_execution(data, step, execution_id)

      _ ->
        execution =
          Repo.one(
            from(execution in StepExecution,
              where:
                execution.task_id == ^data.task.id and
                  execution.task_run_id == ^data.task_run_id and
                  execution.step_id == ^step.id and
                  execution.status == "completed",
              order_by: [desc: execution.inserted_at, desc: execution.id],
              limit: 1
            )
          )

        case execution do
          %StepExecution{} = execution -> {:ok, execution}
          nil -> {:error, :completed_execution_not_found}
        end
    end
  end

  defp fetch_completed_execution(data, step, execution_id) do
    case Repo.get_by(StepExecution,
           id: execution_id,
           task_id: data.task.id,
           task_run_id: data.task_run_id,
           step_id: step.id,
           user_id: data.user_id,
           project_id: data.project_id,
           status: "completed"
         ) do
      %StepExecution{} = execution -> {:ok, execution}
      nil -> {:error, :completed_execution_not_found}
    end
  end

  defp require_output_schema(schema) when is_map(schema), do: :ok
  defp require_output_schema(_schema), do: {:error, :missing_output_schema}

  defp decode_output(output) when is_binary(output), do: StructuredOutput.decode(output)
  defp decode_output(_output), do: {:error, :missing_output}
end
