defmodule Sacrum.Orchestrator.OutputArtifact do
  @moduledoc """
  Persists configured structured step output as a task artifact.

  This is intentionally orchestrator-owned. The daemon only produces the
  structured output; it does not need to know where that output is stored.
  """

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Orchestrator.{FSMData, OutputValidator, PersistenceOptions, StructuredOutput}
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @spec persist(FSMData.t(), WorkflowStep.t(), StepExecution.t()) ::
          :ok | {:error, term()}
  def persist(%FSMData{} = data, %WorkflowStep{} = step, %StepExecution{} = execution) do
    case PersistenceOptions.artifact_logical_name(step.persistence_options) do
      nil -> :ok
      logical_name -> persist_artifact(data, step, execution, logical_name)
    end
  end

  defp persist_artifact(data, step, execution, logical_name) do
    with :ok <- require_output_schema(step.output_schema),
         {:ok, decoded_output} <- decode_output(execution.output),
         :ok <- OutputValidator.validate_output(decoded_output, step.output_schema),
         {:ok, body} <- Jason.encode(decoded_output),
         {:ok, _result} <-
           Artifacts.create_and_link(
             data.user_id,
             data.project_id,
             %{filename: "#{logical_name}.json", body: body},
             %{subject_type: "task", subject_id: data.task.id, logical_name: logical_name}
           ) do
      :ok
    end
  end

  defp require_output_schema(schema) when is_map(schema), do: :ok
  defp require_output_schema(_schema), do: {:error, :missing_output_schema}

  defp decode_output(output) when is_binary(output), do: StructuredOutput.decode(output)
  defp decode_output(_output), do: {:error, :missing_output}
end
