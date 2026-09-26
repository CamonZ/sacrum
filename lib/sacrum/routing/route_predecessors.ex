defmodule Sacrum.Routing.RoutePredecessors do
  @moduledoc """
  Validates route predecessor schemas and references used by route rules.

  Legacy route envelopes declare `route.{result, handoff}`. Structured
  inference predecessors are routed on paths into their output schema (the
  answers schema derived from their questions). Runtime evaluation uses the
  already-built `RouteContext`.
  """

  alias Sacrum.JsonSchema.Strict
  alias Sacrum.Routing.{RouteConfig, Traverse}

  @type type_environment :: %{result_values: MapSet.t(String.t()), predecessors: [map()]}
  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @routable_types ["string", "number", "integer", "boolean"]

  @doc """
  Validates predecessor-result predicates against a derived result-enum union.

  Callers holding raw schemas derive the environment first with
  `derive_type_environment/1`.
  """
  @spec validate(RouteConfig.t(), type_environment()) :: :ok | {:error, error()}
  def validate(%{rules: rules}, %{result_values: result_values, predecessors: predecessors})
      when is_list(rules) do
    with :ok <- validate_structured_rules(rules, predecessors) do
      validate_rules(rules, result_values)
    end
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
  def derive_type_environment(predecessors) when is_list(predecessors) and predecessors != [] do
    with {:ok, environments} <- Traverse.map_while(predecessors, &validate_predecessor(&1, &2)) do
      {:ok, merge_type_environments(environments)}
    end
  end

  def derive_type_environment(_predecessors),
    do:
      {:error, error(:route_input_invalid, "$.predecessors", "must contain at least one schema")}

  defp validate_predecessor(%{output_schema: schema} = predecessor, index) do
    result =
      case Map.get(predecessor, :step_type) do
        :structured_inference -> validate_structured_schema(schema)
        _step_type -> validate_predecessor_schema(schema)
      end

    case result do
      {:ok, environment} ->
        {:ok, Map.put_new(environment, :kind, :route)}

      {:error, %{path: path} = reason} ->
        id = Map.get(predecessor, :transition_id) || index

        {:error,
         reason
         |> Map.merge(
           Map.take(predecessor, [:transition_id, :source_step_id, :destination_step_id])
         )
         |> Map.put(:path, "$.predecessors[#{id}]#{drop_root(path)}")}
    end
  end

  defp validate_predecessor(_predecessor, index) do
    {:error,
     error(:route_input_invalid, "$.predecessors[#{index}]", "must include output_schema")}
  end

  defp merge_type_environments(environments) do
    result_values =
      Enum.reduce(environments, MapSet.new(), fn %{result_values: values}, acc ->
        MapSet.union(acc, values)
      end)

    %{result_values: result_values, predecessors: environments}
  end

  # The answers schema is derived by Sacrum from the step's questions and
  # requires every declared answer property; answers may carry additional
  # provider fields, so it is not a strict schema.
  defp validate_structured_schema(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties),
       do: {:ok, %{result_values: MapSet.new(), schema: schema, kind: :structured}}

  defp validate_structured_schema(_schema),
    do:
      {:error,
       error(:route_input_invalid, "$", "structured predecessor requires an object output schema")}

  defp validate_structured_rules(rules, predecessors) do
    Traverse.each_while(rules, fn %{when: expression}, index ->
      validate_structured_expression(expression, predecessors, "$.rules[#{index}].when")
    end)
  end

  defp validate_structured_expression(%{kind: kind, expressions: expressions}, predecessors, path)
       when kind in [:all, :any] do
    Traverse.each_while(expressions, fn expression, index ->
      validate_structured_expression(expression, predecessors, "#{path}.#{kind}[#{index}]")
    end)
  end

  defp validate_structured_expression(%{kind: :not, expression: expression}, predecessors, path),
    do: validate_structured_expression(expression, predecessors, "#{path}.not")

  defp validate_structured_expression(
         %{kind: :predicate, ref: ref} = predicate,
         predecessors,
         path
       )
       when is_binary(ref) do
    Traverse.each_while(predecessors, fn predecessor, _index ->
      validate_structured_predicate(predicate, predecessor, path)
    end)
  end

  defp validate_structured_expression(
         %{kind: :predicate, ref: :previous_output_route_result},
         predecessors,
         path
       ) do
    if Enum.any?(predecessors, &(&1.kind == :structured)) do
      {:error,
       error(
         :route_config_invalid,
         "#{path}.ref",
         "route.result is unavailable from a structured predecessor"
       )}
    else
      :ok
    end
  end

  defp validate_structured_expression(%{kind: :predicate}, _predecessors, _path), do: :ok

  defp validate_structured_predicate(_predicate, %{kind: kind}, path) when kind != :structured,
    do:
      {:error,
       error(
         :route_config_invalid,
         "#{path}.ref",
         "structured reference is unavailable from this predecessor"
       )}

  defp validate_structured_predicate(
         %{ref: "previous_output." <> ref_path, operator: operator, value: value},
         %{schema: schema},
         path
       ) do
    with {:ok, leaf} <- resolve_schema_path(schema, String.split(ref_path, "."), path) do
      validate_leaf(leaf, operator, value, path)
    end
  end

  defp resolve_schema_path(schema, segments, path) do
    Enum.reduce_while(segments, {:ok, schema}, fn segment, {:ok, current} ->
      case current do
        %{"properties" => %{^segment => child}} ->
          {:cont, {:ok, child}}

        _undeclared ->
          {:halt,
           {:error,
            error(:route_config_invalid, "#{path}.ref", "#{inspect(segment)} is not declared")}}
      end
    end)
  end

  defp validate_leaf(%{"type" => type} = schema, operator, value, path)
       when type in @routable_types do
    with :ok <- validate_typed_value(type, operator, value, path),
         :ok <- validate_declared_enum(schema, operator, value, path) do
      validate_bounds(schema, operator, value, path)
    end
  end

  defp validate_leaf(schema, _operator, _value, path) do
    {:error,
     error(
       :route_operand_type_mismatch,
       "#{path}.ref",
       "#{inspect(schema["type"])} values are not routable; use string, number, integer, or boolean"
     )}
  end

  # A compared value outside the declared range can never be produced, so the
  # rule could only be a typo.
  defp validate_bounds(schema, operator, value, path) do
    values = if operator == :in, do: value, else: [value]
    minimum = Map.get(schema, "minimum")
    maximum = Map.get(schema, "maximum")

    if Enum.all?(values, &within_bounds?(&1, minimum, maximum)) do
      :ok
    else
      {:error,
       error(
         :route_operand_type_mismatch,
         "#{path}.value",
         "must be within #{inspect(minimum)} and #{inspect(maximum)}"
       )}
    end
  end

  defp within_bounds?(value, minimum, maximum) when is_number(value),
    do: (is_nil(minimum) or value >= minimum) and (is_nil(maximum) or value <= maximum)

  defp within_bounds?(_value, _minimum, _maximum), do: true

  defp validate_declared_enum(%{"enum" => enum}, operator, value, path) when is_list(enum) do
    values = if operator == :in, do: value, else: [value]

    case Enum.find(values, &(&1 not in enum)) do
      nil ->
        :ok

      undeclared ->
        {:error,
         error(:route_config_invalid, "#{path}.value", "#{inspect(undeclared)} is not declared")}
    end
  end

  defp validate_declared_enum(_schema, _operator, _value, _path), do: :ok

  defp validate_typed_value(type, operator, value, path) do
    values = if operator == :in, do: value, else: [value]

    valid? =
      is_list(values) and values != [] and
        Enum.all?(values, &valid_typed_item?(type, operator, &1))

    if valid?,
      do: :ok,
      else:
        {:error,
         error(
           :route_operand_type_mismatch,
           "#{path}.value",
           "does not match the referenced field type"
         )}
  end

  defp valid_typed_item?("string", operator, value),
    do: is_binary(value) and operator not in [:lt, :lte, :gt, :gte]

  defp valid_typed_item?("number", _operator, value), do: is_number(value)
  defp valid_typed_item?("integer", _operator, value), do: is_integer(value)

  defp valid_typed_item?("boolean", operator, value),
    do: is_boolean(value) and operator not in [:lt, :lte, :gt, :gte]

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
