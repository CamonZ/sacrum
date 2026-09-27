defmodule Sacrum.Routing.RoutePredecessors do
  @moduledoc """
  Proves route references against every incoming predecessor's output schema.

  A route owns its handoff: predecessors only declare an output schema, and
  the route's rule references (`previous_output.<path>`) and handoff template
  references (`{{ previous_output.<path> }}`) are resolved against each
  incoming predecessor schema with one schema-path resolver. Runtime
  evaluation uses the already-built `RouteContext`.
  """

  alias Sacrum.Routing.{HandoffTemplate, RouteConfig, RouteValue, Traverse}

  @type predecessor :: %{
          optional(:transition_id) => term(),
          optional(:source_step_id) => binary(),
          optional(:destination_step_id) => binary(),
          schema: map()
        }
  @type type_environment :: %{predecessors: [predecessor()]}
  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @routable_types ["string", "number", "integer", "boolean"]
  @container_types ["object", "array"]

  @doc """
  Validates rule and handoff references against every predecessor schema.

  Callers holding raw schemas derive the environment first with
  `derive_type_environment/1`.
  """
  @spec validate(RouteConfig.t(), type_environment()) :: :ok | {:error, error()}
  def validate(%{rules: rules} = program, %{predecessors: predecessors}) when is_list(rules) do
    with :ok <- validate_rules(rules, predecessors) do
      validate_handoffs(program, predecessors)
    end
  end

  def validate(_program, _type_environment),
    do: {:error, error(:route_config_invalid, "$", "must be a decoded route program")}

  @doc """
  Collects the incoming predecessor output schemas a route reads.

  Every predecessor must declare an object output schema; `llm_inference`
  steps that feed a route must configure `output_schema`, and
  `structured_inference` steps use the answers schema derived from their
  questions.
  """
  @spec derive_type_environment([map()]) :: {:ok, type_environment()} | {:error, error()}
  def derive_type_environment(predecessors) when is_list(predecessors) and predecessors != [] do
    with {:ok, predecessors} <- Traverse.map_while(predecessors, &validate_predecessor(&1, &2)) do
      {:ok, %{predecessors: predecessors}}
    end
  end

  def derive_type_environment(_predecessors),
    do:
      {:error, error(:route_input_invalid, "$.predecessors", "must contain at least one schema")}

  @doc """
  Returns the finite value domain of each rule reference that every
  predecessor declares as a required string enum.

  Values are the union across predecessors. References missing from the map
  are open: they cannot be enumerated, so their rules need a default.
  """
  @spec closed_domains(RouteConfig.t(), type_environment()) :: %{
          optional(String.t()) => [String.t()]
        }
  def closed_domains(program, %{predecessors: predecessors}) do
    program
    |> RouteConfig.output_references()
    |> Enum.reduce(%{}, fn reference, domains ->
      case closed_domain(reference, predecessors) do
        {:ok, values} -> Map.put(domains, reference, values)
        :open -> domains
      end
    end)
  end

  defp closed_domain("previous_output." <> path, predecessors) do
    segments = String.split(path, ".")

    Enum.reduce_while(predecessors, {:ok, []}, fn %{schema: schema}, {:ok, values} ->
      case resolve(schema, segments) do
        {:ok, %{"type" => "string", "enum" => enum}, nil} when is_list(enum) and enum != [] ->
          {:cont, {:ok, Enum.uniq(values ++ enum)}}

        _open ->
          {:halt, :open}
      end
    end)
  end

  @spec leaf_schema(map(), String.t()) :: {:ok, map()} | :undeclared
  def leaf_schema(schema, "previous_output." <> path) do
    case resolve(schema, String.split(path, ".")) do
      {:ok, leaf, _optional} -> {:ok, leaf}
      {:undeclared, _segment} -> :undeclared
    end
  end

  def leaf_schema(_schema, _reference), do: :undeclared

  defp validate_predecessor(predecessor, index) do
    id = Map.get(predecessor, :transition_id) || index

    case validate_schema(Map.get(predecessor, :output_schema), Map.get(predecessor, :step_type)) do
      {:ok, schema} ->
        {:ok,
         predecessor
         |> Map.take([:transition_id, :source_step_id, :destination_step_id])
         |> Map.put(:schema, schema)}

      {:error, %{path: path} = reason} ->
        {:error,
         reason
         |> Map.merge(
           Map.take(predecessor, [:transition_id, :source_step_id, :destination_step_id])
         )
         |> Map.put(:path, "$.predecessors[#{id}]#{drop_root(path)}")}
    end
  end

  defp validate_schema(nil, :llm_inference),
    do:
      {:error,
       error(
         :route_input_invalid,
         "$.output_schema",
         "is required for llm_inference steps that feed a route"
       )}

  defp validate_schema(nil, _step_type),
    do: {:error, error(:route_input_invalid, "$.output_schema", "is required to feed a route")}

  defp validate_schema(%{"type" => "object", "properties" => properties} = schema, _step_type)
       when is_map(properties),
       do: {:ok, schema}

  defp validate_schema(_schema, _step_type),
    do:
      {:error,
       error(:route_input_invalid, "$.output_schema", "must be an object schema with properties")}

  #
  # Schema-path resolution shared by rule and handoff references.
  #

  # Returns the leaf schema and the first segment that is not required on the
  # way to it (nil when every segment is required), or the first undeclared
  # segment.
  defp resolve(schema, segments),
    do: Enum.reduce_while(segments, {:ok, schema, nil}, &resolve_segment/2)

  defp resolve_segment(segment, {:ok, %{"properties" => %{} = properties} = current, optional})
       when is_map_key(properties, segment) do
    optional = optional || if(required?(current, segment), do: nil, else: segment)
    {:cont, {:ok, Map.fetch!(properties, segment), optional}}
  end

  defp resolve_segment(segment, _acc), do: {:halt, {:undeclared, segment}}

  defp required?(%{"required" => required}, segment) when is_list(required),
    do: segment in required

  defp required?(_schema, _segment), do: false

  #
  # Rule references
  #

  defp validate_rules(rules, predecessors) do
    Traverse.each_while(rules, fn %{when: expression}, index ->
      path = "$.rules[#{index}].when"

      expression
      |> predicate_paths(path)
      |> Traverse.each_while(fn {predicate, predicate_path}, _index ->
        validate_predicate(predicate, predecessors, predicate_path)
      end)
    end)
  end

  defp predicate_paths(%{kind: kind, expressions: expressions}, path) when kind in [:all, :any] do
    expressions
    |> Enum.with_index()
    |> Enum.flat_map(fn {expression, index} ->
      predicate_paths(expression, "#{path}.#{kind}[#{index}]")
    end)
  end

  defp predicate_paths(%{kind: :not, expression: expression}, path),
    do: predicate_paths(expression, "#{path}.not")

  defp predicate_paths(%{kind: :predicate} = predicate, path), do: [{predicate, path}]

  defp validate_predicate(
         %{ref: "previous_output." <> ref_path, operator: operator, value: value},
         predecessors,
         path
       ) do
    segments = String.split(ref_path, ".")

    with {:ok, leaves} <-
           Traverse.map_while(predecessors, fn %{schema: schema}, _index ->
             resolve_rule_leaf(schema, segments, path)
           end),
         :ok <-
           Traverse.each_while(leaves, fn leaf, _index ->
             validate_leaf(leaf, operator, value, path)
           end) do
      validate_declared_enum(leaves, operator, value, path)
    end
  end

  defp validate_predicate(%{kind: :predicate}, _predecessors, _path), do: :ok

  defp resolve_rule_leaf(schema, segments, path) do
    case resolve(schema, segments) do
      {:ok, leaf, _optional} ->
        {:ok, leaf}

      {:undeclared, segment} ->
        {:error,
         error(:route_config_invalid, "#{path}.ref", "#{inspect(segment)} is not declared")}
    end
  end

  defp validate_leaf(%{"type" => type} = schema, operator, value, path)
       when type in @routable_types do
    with :ok <- validate_typed_value(type, operator, value, path) do
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
    do:
      (is_nil(minimum) or RouteValue.compare(value, minimum) != :lt) and
        (is_nil(maximum) or RouteValue.compare(value, maximum) != :gt)

  defp within_bounds?(_value, _minimum, _maximum), do: true

  # A compared value is valid when any predecessor can produce it, so enum
  # membership is checked against the union of the predecessors' enums. A
  # predecessor without an enum leaves the value open.
  defp validate_declared_enum(leaves, operator, value, path) do
    if Enum.all?(leaves, &is_list(&1["enum"])) do
      enum = Enum.flat_map(leaves, & &1["enum"])
      values = if operator == :in, do: value, else: [value]

      case Enum.find(values, &(not RouteValue.member?(&1, enum))) do
        nil ->
          :ok

        undeclared ->
          {:error,
           error(:route_config_invalid, "#{path}.value", "#{inspect(undeclared)} is not declared")}
      end
    else
      :ok
    end
  end

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

  #
  # Handoff references
  #

  defp validate_handoffs(%{rules: rules, default: default}, predecessors) do
    rule_decisions =
      rules
      |> Enum.with_index()
      |> Enum.map(fn {rule, index} -> {rule.handoff, "$.rules[#{index}].handoff"} end)

    default_decisions = if default, do: [{default.handoff, "$.default.handoff"}], else: []

    (rule_decisions ++ default_decisions)
    |> Enum.flat_map(fn {template, path} -> HandoffTemplate.references(template, path) end)
    |> Traverse.each_while(fn interpolation, _index ->
      validate_handoff_reference(interpolation, predecessors)
    end)
  end

  defp validate_handoff_reference(
         %{reference: "previous_output." <> ref_path} = ref,
         predecessors
       ) do
    segments = String.split(ref_path, ".")

    Traverse.each_while(predecessors, fn %{schema: schema}, _index ->
      case resolve(schema, segments) do
        {:ok, leaf, optional} ->
          validate_handoff_leaf(leaf, optional, ref)

        {:undeclared, segment} ->
          handoff_error(ref, "#{inspect(segment)} is not declared")
      end
    end)
  end

  defp validate_handoff_reference(_ref, _predecessors), do: :ok

  defp validate_handoff_leaf(_leaf, segment, %{optional?: false} = ref) when is_binary(segment),
    do:
      handoff_error(
        ref,
        "#{inspect(segment)} is not required; mark the reference optional with ?"
      )

  defp validate_handoff_leaf(leaf, _optional, %{embedded?: true} = ref) do
    if container?(leaf["type"]),
      do:
        handoff_error(
          ref,
          "object and array interpolations must occupy the whole string to preserve their JSON type"
        ),
      else: :ok
  end

  defp validate_handoff_leaf(_leaf, _optional, _ref), do: :ok

  defp container?(type) when is_binary(type), do: type in @container_types
  defp container?(types) when is_list(types), do: Enum.any?(types, &(&1 in @container_types))
  defp container?(_type), do: false

  defp handoff_error(%{path: path, reference: reference}, message) do
    {:error,
     error(
       :route_handoff_template_invalid,
       path,
       "interpolation reference #{inspect(reference)}: #{message}"
     )}
  end

  defp drop_root("$"), do: ""
  defp drop_root(path), do: String.replace_prefix(path, "$", "")

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
