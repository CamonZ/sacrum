defmodule Sacrum.Orchestrator.StructuredInference do
  @moduledoc """
  Result contract for `structured_inference` executions.

  A provider harness completes the execution with an output string encoding
  the provider's answers map, keyed by question id, exactly as the provider
  returned it. The answers must satisfy the schema derived from the questions
  in the execution's rendered config (`WorkflowStep.output_schema/1`); a
  conforming result is stored unchanged in `StepExecution.output`, and a
  non-conforming one fails the execution instead of being stored as
  successful output.
  """

  alias Sacrum.Orchestrator.OutputValidator
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @doc """
  Prepares a `StepExecution` update. For structured_inference executions an
  update that completes the execution, or changes a completed execution's
  output, carries a harness result that is validated before it is stored.
  Other executions are returned unchanged.
  """
  @spec prepare_update(StepExecution.t(), map()) :: map()
  def prepare_update(%StepExecution{step_type: :structured_inference} = execution, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    if completes?(execution, attrs) do
      Map.merge(attrs, complete(execution, Map.get(attrs, "output", execution.output)))
    else
      attrs
    end
  end

  def prepare_update(_execution, attrs), do: attrs

  defp completes?(execution, attrs) do
    Map.get(attrs, "status", execution.status) == "completed" and
      (Map.has_key?(attrs, "output") or execution.status != "completed")
  end

  @doc """
  Validates a harness result against the answers schema derived from the
  execution's rendered config and returns the attrs to store: the result
  unchanged as `output`, or a failed-status update carrying the rejection
  reason.
  """
  @spec complete(WorkflowStep.with_config(), term()) :: map()
  def complete(execution, raw_output) do
    with {:ok, schema} <- fetch_schema(execution),
         {:ok, answers} <- decode(raw_output),
         :ok <- validate(answers, schema) do
      %{"output" => raw_output}
    else
      {:error, reason} ->
        %{"status" => "failed", "output" => "structured output rejected: #{reason}"}
    end
  end

  defp fetch_schema(execution) do
    case WorkflowStep.output_schema(execution) do
      schema when is_map(schema) -> {:ok, schema}
      nil -> {:error, "execution config is missing questions"}
    end
  end

  defp decode(raw_output) when is_binary(raw_output) do
    case Jason.decode(raw_output) do
      {:ok, answers} -> {:ok, answers}
      {:error, _reason} -> {:error, "answers must be valid JSON"}
    end
  end

  defp decode(_raw_output), do: {:error, "answers are missing"}

  defp validate(answers, schema) do
    case OutputValidator.validate_output(answers, schema) do
      :ok -> :ok
      {:error, {:validation_failed, errors}} -> {:error, "answers #{Enum.join(errors, "; ")}"}
      {:error, reason} -> {:error, "answers #{inspect(reason)}"}
    end
  end
end
