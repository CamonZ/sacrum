defmodule Sacrum.JsonSchema.Strict do
  @moduledoc """
  Validates the strict JSON Schema subset accepted by Codex.

  This is deliberately independent of Ecto schemas so output contracts and
  routing predecessor envelopes can share the same structural check.
  """

  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(schema) when is_map(schema), do: validate(schema, "schema")
  def validate(_schema), do: {:error, "schema must be a map"}

  defp validate(schema, path) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") ->
        {:error, "#{path}.const is not supported"}

      is_list(schema["type"]) ->
        {:error, "#{path}.type must be a single string, not a type array"}

      not is_binary(schema["type"]) ->
        {:error, "#{path}.type must be a string"}

      schema["type"] == "object" ->
        validate_object(schema, path)

      schema["type"] == "array" ->
        validate_array(schema, path)

      true ->
        :ok
    end
  end

  defp validate(_schema, path), do: {:error, "#{path} must be a schema object"}

  defp validate_object(schema, path) do
    with :ok <-
           require_exact_value(
             schema,
             "additionalProperties",
             false,
             "#{path}.additionalProperties must be false"
           ),
         {:ok, properties} <- fetch_map(schema, "properties", "#{path}.properties must be a map"),
         :ok <- validate_required_keys(schema, Map.keys(properties), "#{path}.required") do
      validate_properties(properties, path)
    end
  end

  defp validate_properties(properties, path) do
    Enum.reduce_while(properties, :ok, fn {key, property_schema}, :ok ->
      case validate(property_schema, "#{path}.#{key}") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_array(schema, path) do
    case Map.get(schema, "items") do
      items when is_map(items) -> validate(items, "#{path}.items")
      _ -> {:error, "#{path}.items must be a schema object"}
    end
  end

  defp validate_required_keys(schema, property_keys, label) do
    case Map.get(schema, "required") do
      required when is_list(required) ->
        if Enum.sort(required) == Enum.sort(property_keys) do
          :ok
        else
          {:error, "#{label} must list every declared property"}
        end

      _ ->
        {:error, "#{label} must list every declared property"}
    end
  end

  defp require_exact_value(schema, key, expected, error_message) do
    if Map.get(schema, key) == expected, do: :ok, else: {:error, error_message}
  end

  defp fetch_map(schema, key, error_message) do
    case Map.get(schema, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, error_message}
    end
  end
end
