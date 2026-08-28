defmodule Sacrum.Routing.RoutePredecessors do
  @moduledoc """
  Validates route predecessor envelopes and their declared result enums.

  The predecessor envelope is `route.{result, handoff}`. Handoff objects use
  the shared strict JSON Schema subset; result values are a string enum. Runtime
  evaluation uses the already-built `RouteContext` instead of this module.
  """

  alias Sacrum.JsonSchema.Strict
  alias Sacrum.Routing.{RouteConfig, Traverse}

  @type type_environment :: %{result_values: MapSet.t(String.t())}
  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Validates predecessor-result predicates against a derived result-enum union.

  Callers holding raw schemas derive the environment first with
  `derive_type_environment/1`.
  """
  @spec validate(RouteConfig.t(), type_environment()) :: :ok | {:error, error()}
  def validate(%{rules: rules}, %{result_values: result_values}) when is_list(rules) do
    validate_rules(rules, result_values)
  end

  def validate(_program, _type_environment),
    do: {:error, error(:route_config_invalid, "$", "must be a decoded route program")}

  @doc """
  Validates one predecessor output schema and returns its route-result enum.
  """
  @spec validate_predecessor_schema(map()) :: {:ok, type_environment()} | {:error, error()}
  def validate_predecessor_schema(schema) when is_map(schema) do
    with {:ok, properties} <- fetch_object(schema, "properties", "$.properties"),
         :ok <- require_route_key(schema, properties),
         {:ok, route} <- fetch_object(properties, "route", "$.properties.route"),
         :ok <-
           typed_error(
             Strict.require_exact_value(route, "type", "object", "must be object"),
             "$.properties.route.type"
           ),
         :ok <-
           typed_error(
             Strict.require_exact_value(
               route,
               "additionalProperties",
               false,
               "must be false"
             ),
             "$.properties.route.additionalProperties"
           ),
         :ok <-
           require_included_keys(
             route["required"],
             ["result", "handoff"],
             "$.properties.route.required"
           ),
         {:ok, route_properties} <-
           fetch_object(route, "properties", "$.properties.route.properties"),
         {:ok, result_values} <- validate_result_schema(route_properties["result"]),
         :ok <- validate_handoff_schema(route_properties["handoff"]) do
      {:ok, %{result_values: MapSet.new(result_values)}}
    end
  end

  def validate_predecessor_schema(_schema),
    do: {:error, error(:route_input_invalid, "$", "predecessor schema must be an object")}

  @doc """
  Merges the result enum declarations from all legal incoming predecessors.
  """
  @spec derive_type_environment([map()]) :: {:ok, type_environment()} | {:error, error()}
  def derive_type_environment([%{output_schema: _} | _] = predecessors) do
    with {:ok, environments} <-
           Traverse.map_while(predecessors, &validate_loaded_predecessor(&1, &2)) do
      {:ok, merge_type_environments(environments)}
    end
  end

  def derive_type_environment(schemas) when is_list(schemas) and schemas != [] do
    with {:ok, environments} <- Traverse.map_while(schemas, &validate_schema(&1, &2)) do
      {:ok, merge_type_environments(environments)}
    end
  end

  def derive_type_environment(_schemas),
    do:
      {:error, error(:route_input_invalid, "$.predecessors", "must contain at least one schema")}

  defp validate_schema(schema, index) do
    case validate_predecessor_schema(schema) do
      {:ok, environment} ->
        {:ok, environment}

      {:error, %{path: path} = reason} ->
        {:error, %{reason | path: "$.predecessors[#{index}]#{drop_root(path)}"}}
    end
  end

  defp validate_loaded_predecessor(%{output_schema: schema} = predecessor, _index) do
    case validate_predecessor_schema(schema) do
      {:ok, environment} ->
        {:ok, environment}

      {:error, %{path: path} = reason} ->
        {:error,
         reason
         |> Map.merge(
           Map.take(predecessor, [:transition_id, :source_step_id, :destination_step_id])
         )
         |> Map.put(:path, "$.predecessors[#{predecessor.transition_id}]#{drop_root(path)}")}
    end
  end

  defp merge_type_environments(environments) do
    result_values =
      Enum.reduce(environments, MapSet.new(), fn %{result_values: values}, acc ->
        MapSet.union(acc, values)
      end)

    %{result_values: result_values}
  end

  defp validate_rules(rules, result_values) do
    Traverse.each_while(rules, fn %{when: expression}, index ->
      validate_expression(expression, result_values, "$.rules[#{index}].when")
    end)
  end

  defp validate_expression(%{kind: kind, expressions: expressions}, result_values, path)
       when kind in [:all, :any] do
    Traverse.each_while(expressions, fn expression, index ->
      validate_expression(expression, result_values, "#{path}.#{kind}[#{index}]")
    end)
  end

  defp validate_expression(%{kind: :not, expression: expression}, result_values, path),
    do: validate_expression(expression, result_values, "#{path}.not")

  defp validate_expression(
         %{
           kind: :predicate,
           ref: :previous_output_route_result,
           operator: operator,
           value: value
         },
         result_values,
         path
       ) do
    values = if operator == :in, do: value, else: [value]

    case Enum.find(values, &(not MapSet.member?(result_values, &1))) do
      nil ->
        :ok

      undeclared ->
        {:error,
         error(:route_config_invalid, "#{path}.value", "#{inspect(undeclared)} is not declared")}
    end
  end

  defp validate_expression(%{kind: :predicate}, _result_values, _path), do: :ok

  defp require_route_key(schema, properties) do
    required = schema["required"]

    cond do
      not is_list(required) ->
        {:error, error(:route_input_invalid, "$.required", "must include route")}

      "route" not in required or not Map.has_key?(properties, "route") ->
        {:error, error(:route_input_invalid, "$.properties.route", "is required")}

      true ->
        :ok
    end
  end

  defp validate_result_schema(%{"type" => "string", "enum" => values}) when is_list(values) do
    if values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")) and
         length(values) == length(Enum.uniq(values)) do
      {:ok, values}
    else
      {:error,
       error(
         :route_input_invalid,
         "$.properties.route.properties.result.enum",
         "must be a unique non-empty string enum"
       )}
    end
  end

  defp validate_result_schema(_result) do
    {:error,
     error(
       :route_input_invalid,
       "$.properties.route.properties.result",
       "must be a string with a non-empty enum"
     )}
  end

  defp validate_handoff_schema(%{"type" => "object"} = handoff) do
    case Strict.validate(handoff) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, error(:route_input_invalid, "$.properties.route.properties.handoff", message)}
    end
  end

  defp validate_handoff_schema(_handoff) do
    {:error,
     error(
       :route_input_invalid,
       "$.properties.route.properties.handoff",
       "must be a strict object schema"
     )}
  end

  defp fetch_object(map, key, path) do
    case Strict.fetch_map(map, key, "must be an object") do
      {:ok, value} -> {:ok, value}
      {:error, message} -> {:error, error(:route_input_invalid, path, message)}
    end
  end

  defp require_included_keys(keys, required, path) when is_list(keys) do
    if Enum.all?(required, &(&1 in keys)) do
      :ok
    else
      {:error, error(:route_input_invalid, path, "must include #{Enum.join(required, ", ")}")}
    end
  end

  defp require_included_keys(_keys, _required, path),
    do: {:error, error(:route_input_invalid, path, "must be an array")}

  defp typed_error(:ok, _path), do: :ok

  defp typed_error({:error, message}, path),
    do: {:error, error(:route_input_invalid, path, message)}

  defp drop_root("$"), do: ""
  defp drop_root(path), do: String.replace_prefix(path, "$", "")

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
