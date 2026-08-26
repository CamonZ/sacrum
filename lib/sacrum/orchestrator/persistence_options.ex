defmodule Sacrum.Orchestrator.PersistenceOptions do
  @moduledoc """
  Validates and reads workflow-step persistence configuration.

  The persisted value is configuration, not the output contract itself. The
  output contract remains on `WorkflowStep.output_schema`.
  """

  alias Sacrum.Orchestrator.OutputValidator

  @schema %{
    "type" => "object",
    "properties" => %{
      "artifact" => %{
        "type" => "object",
        "properties" => %{
          "logical_name" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 255
          }
        },
        "required" => ["logical_name"],
        "additionalProperties" => false
      }
    },
    "additionalProperties" => false
  }

  @resolved_schema ExJsonSchema.Schema.resolve(@schema)

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok

  def validate(options) when is_map(options) do
    case ExJsonSchema.Validator.validate(@resolved_schema, options) do
      :ok ->
        validate_artifact_logical_name(options)

      {:error, errors} ->
        {:error, format_errors(errors)}
    end
  rescue
    _error -> {:error, "must be a valid persistence options object"}
  end

  def validate(_options), do: {:error, "must be a map or null"}

  @spec artifact_logical_name(term()) :: String.t() | nil
  def artifact_logical_name(%{"artifact" => %{"logical_name" => logical_name}}),
    do: logical_name

  def artifact_logical_name(_options), do: nil

  defp validate_artifact_logical_name(options) do
    case artifact_logical_name(options) do
      logical_name when is_binary(logical_name) ->
        if String.trim(logical_name) == "" do
          {:error, "artifact.logical_name: can't be blank"}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp format_errors(errors) do
    Enum.map_join(errors, ", ", &OutputValidator.format_error/1)
  end
end
