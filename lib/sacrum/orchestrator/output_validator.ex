defmodule Sacrum.Orchestrator.OutputValidator do
  @moduledoc """
  Validates step execution output against JSON Schema definitions.
  """

  require Logger

  alias Sacrum.Repo.Schemas.WorkflowStep

  @doc """
  Validates output against a step's output schema.

  Returns `:ok` if output is valid or no schema is defined,
  `{:error, reason}` if validation fails.
  """
  @spec validate_output(any(), map() | nil) :: :ok | {:error, term()}
  def validate_output(_output, nil), do: :ok

  def validate_output(output, schema) when is_map(schema) do
    resolved_schema = ExJsonSchema.Schema.resolve(schema)

    case ExJsonSchema.Validator.validate(resolved_schema, output) do
      :ok ->
        :ok

      {:error, errors} ->
        formatted_errors = Enum.map(errors, &format_error/1)
        {:error, {:validation_failed, formatted_errors}}
    end
  rescue
    error ->
      Logger.error("[OutputValidator] Error during validation: #{inspect(error)}")
      {:error, {:invalid_schema, error}}
  end

  def validate_output(_output, _schema) do
    {:error, {:invalid_schema_type, "schema must be a map"}}
  end

  @doc """
  Validates routing contract output for route steps using the canonical
  routing contract schema from `WorkflowStep.routing_contract_schema/0`.
  """
  @spec validate_routing_contract(any()) :: :ok | {:error, term()}
  def validate_routing_contract(output) when is_map(output) do
    validate_output(output, WorkflowStep.routing_contract_schema())
  end

  def validate_routing_contract(_output) do
    {:error, {:invalid_output_type, "routing contract output must be a map"}}
  end

  defp format_error({message, path}) when is_binary(message) and is_binary(path) do
    "#{path}: #{message}"
  end

  defp format_error({message, path}) when is_binary(message) do
    "#{inspect(path)}: #{message}"
  end

  defp format_error(error) do
    "#{inspect(error)}"
  end
end
