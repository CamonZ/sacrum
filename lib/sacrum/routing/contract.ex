defmodule Sacrum.Routing.Contract do
  @moduledoc """
  Canonical JSON Schema for legacy route-step model output.

  Route steps that still dispatch to a daemon must emit
  `transition_to` / `transition_type` (and optional `handoff`). Deterministic
  routes ignore this contract at runtime; persist-time validation still uses
  it whenever an `output_schema` is supplied on a route step.
  """

  alias Sacrum.JsonSchema.Strict

  @spec output_schema() :: map()
  def output_schema, do: output_schema(nil)

  @spec output_schema(map() | nil) :: map()
  def output_schema(nil) do
    %{
      "type" => "object",
      "properties" => %{
        "transition_to" => %{"type" => "string"},
        "transition_type" => %{"type" => "string", "enum" => ["intra_workflow", "inter_workflow"]}
      },
      "required" => ["transition_to", "transition_type"],
      "additionalProperties" => false
    }
  end

  def output_schema(handoff_schema) when is_map(handoff_schema) do
    schema = output_schema(nil)

    schema
    |> put_in(["properties", "handoff"], handoff_schema)
    |> put_in(["required"], ["transition_to", "transition_type", "handoff"])
  end

  @spec validate_output_schema(term()) :: :ok | {:error, String.t()}
  def validate_output_schema(schema) when is_map(schema) do
    with :ok <-
           Strict.require_exact_value(schema, "type", "object", "top-level type must be object"),
         :ok <-
           Strict.require_exact_value(
             schema,
             "additionalProperties",
             false,
             "top-level additionalProperties must be false"
           ),
         {:ok, properties} <-
           Strict.fetch_map(schema, "properties", "properties must be a map"),
         :ok <- validate_route_properties(properties) do
      validate_required_keys(schema, Map.keys(properties), "top-level required")
    end
  end

  def validate_output_schema(_schema), do: {:error, "schema must be a map"}

  defp validate_route_properties(properties) do
    property_keys = Map.keys(properties)

    cond do
      Enum.sort(property_keys) not in [
        ["transition_to", "transition_type"],
        ["handoff", "transition_to", "transition_type"]
      ] ->
        {:error,
         "properties must contain transition_to, transition_type, and optional handoff only"}

      properties["transition_to"] != %{"type" => "string"} ->
        {:error, "transition_to must be a string schema without format"}

      properties["transition_type"] != %{
        "type" => "string",
        "enum" => ["intra_workflow", "inter_workflow"]
      } ->
        {:error, "transition_type must allow intra_workflow and inter_workflow"}

      handoff_schema = properties["handoff"] ->
        validate_strict_object_schema(handoff_schema, "handoff")

      true ->
        :ok
    end
  end

  defp validate_strict_object_schema(schema, path) when is_map(schema) do
    with :ok <- require_object_type(schema, path),
         :ok <-
           Strict.require_exact_value(
             schema,
             "additionalProperties",
             false,
             "#{path}.additionalProperties must be false"
           ),
         {:ok, properties} <- optional_properties(schema, path),
         :ok <- validate_required_keys(schema, Map.keys(properties), "#{path}.required") do
      validate_nested_schemas(properties, path)
    end
  end

  defp validate_strict_object_schema(_schema, path),
    do: {:error, "#{path} must be an object schema"}

  defp validate_nested_schemas(properties, path) do
    Enum.reduce_while(properties, :ok, fn {key, property_schema}, :ok ->
      case validate_nested_schema(property_schema, "#{path}.#{key}") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_nested_schema(schema, path) when is_map(schema) do
    with :ok <- validate_nested_object_schema(schema, path) do
      validate_items_schema(schema, path)
    end
  end

  defp validate_nested_schema(_schema, _path), do: :ok

  defp validate_nested_object_schema(schema, path) do
    if object_schema?(schema) do
      validate_strict_object_schema(schema, path)
    else
      :ok
    end
  end

  defp validate_items_schema(%{"items" => items}, path) when is_map(items) do
    validate_nested_schema(items, "#{path}.items")
  end

  defp validate_items_schema(%{"items" => items}, path) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item_schema, index}, :ok ->
      case validate_nested_schema(item_schema, "#{path}.items[#{index}]") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_items_schema(_schema, _path), do: :ok

  defp object_schema?(schema) do
    type = schema["type"]

    type == "object" or
      (is_list(type) and "object" in type and Enum.all?(type, &(&1 in ["object", "null"])))
  end

  defp require_object_type(schema, path) do
    if object_schema?(schema) do
      :ok
    else
      {:error, "#{path}.type must be object or nullable object"}
    end
  end

  defp optional_properties(schema, path) do
    case Map.get(schema, "properties", %{}) do
      properties when is_map(properties) -> {:ok, properties}
      _ -> {:error, "#{path}.properties must be a map when present"}
    end
  end

  defp validate_required_keys(schema, property_keys, label) do
    required = Map.get(schema, "required")

    cond do
      not is_list(required) ->
        {:error, "#{label} must list every declared property"}

      Enum.sort(required) != Enum.sort(property_keys) ->
        {:error, "#{label} must list every declared property"}

      true ->
        :ok
    end
  end
end
