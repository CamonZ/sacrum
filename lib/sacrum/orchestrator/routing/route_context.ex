defmodule Sacrum.Orchestrator.Routing.RouteContext do
  @moduledoc """
  Builds and statically checks the closed context used by deterministic routes.

  This module deliberately accepts only the four V1 route references. It does
  not derive its data from `PromptContext` and has no database dependencies.
  """

  alias Sacrum.Repo.Schemas.WorkflowStep

  @levels MapSet.new(["epic", "ticket", "task"])

  @operator_sets %{
    previous_output_route_result: MapSet.new([:eq, :neq, :in]),
    task_level: MapSet.new([:eq, :neq, :in]),
    task_tags: MapSet.new([:contains, :contains_any, :contains_all]),
    execution_step_visit_count: MapSet.new([:eq, :neq, :lt, :lte, :gt, :gte, :in])
  }

  @type t :: %{
          previous_output: %{route: %{result: String.t(), handoff: map()}},
          task: %{level: String.t(), tags: [String.t()]},
          execution: %{step_visit_count: pos_integer()}
        }

  @type type_environment :: %{result_values: MapSet.t(String.t())}
  @type result_values :: MapSet.t(String.t()) | :unknown_result_values
  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Builds the complete runtime RouteContext from JSON-shaped route inputs.

  Both `previous_output` and `task` use string keys at this boundary. The
  resulting RouteContext uses its internal atom-keyed representation.
  """
  @spec build(map(), map(), term()) :: {:ok, t()} | {:error, error()}
  def build(previous_output, task, step_visit_count)
      when is_map(previous_output) and is_map(task) do
    with {:ok, result, handoff} <- decode_route_output(previous_output),
         {:ok, normalized_task} <- decode_task(task),
         :ok <- validate_visit_count(step_visit_count) do
      {:ok,
       %{
         previous_output: %{route: %{result: result, handoff: handoff}},
         task: normalized_task,
         execution: %{step_visit_count: step_visit_count}
       }}
    end
  end

  def build(_previous_output, _task, _step_visit_count),
    do: {:error, error(:route_input_invalid, "$", "must include previous output and task maps")}

  @doc """
  Returns a single whitelisted value from a RouteContext.
  """
  @spec fetch(t(), atom()) :: {:ok, term()} | {:error, error()}
  def fetch(context, :previous_output_route_result),
    do: {:ok, get_in(context, [:previous_output, :route, :result])}

  def fetch(context, :task_level), do: {:ok, get_in(context, [:task, :level])}
  def fetch(context, :task_tags), do: {:ok, get_in(context, [:task, :tags])}

  def fetch(context, :execution_step_visit_count),
    do: {:ok, get_in(context, [:execution, :step_visit_count])}

  def fetch(_context, reference),
    do: {:error, error(:route_reference_unknown, "$", "#{inspect(reference)} is not routable")}

  @doc """
  Validates every type rule that does not depend on a predecessor result enum.

  Use this at write and evaluation boundaries. Where predecessor schemas are
  available, use validate/2 with their declared result enum as well.
  """
  @spec validate(map()) :: :ok | {:error, error()}
  def validate(program), do: validate(program, :unknown_result_values)

  @doc """
  Validates a decoded route program against its predecessor result enum union.
  """
  @spec validate(map(), type_environment() | [String.t()] | result_values()) ::
          :ok | {:error, error()}
  def validate(%{rules: rules, default: default}, environment) when is_list(rules) do
    case result_values(environment) do
      {:ok, result_values} -> validate_rules_and_default(rules, default, result_values)
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_program, _environment),
    do: {:error, error(:route_config_invalid, "$", "must be a decoded route program")}

  @doc """
  Validates one predecessor output schema and returns its declared route result
  enum. Handoff schemas are validated for strict object structure but are not
  merged because routes copy them unchanged.
  """
  @spec validate_predecessor_schema(map()) :: {:ok, type_environment()} | {:error, error()}
  def validate_predecessor_schema(schema) when is_map(schema) do
    with :ok <- require_route_property(schema),
         {:ok, route} <- fetch_map(schema["properties"], "route", "$.properties.route"),
         :ok <- require_exact_value(route, "type", "object", "$.properties.route.type"),
         :ok <-
           require_exact_value(
             route,
             "additionalProperties",
             false,
             "$.properties.route.additionalProperties"
           ),
         :ok <-
           require_keys(route["required"], ["result", "handoff"], "$.properties.route.required"),
         {:ok, properties} <- fetch_map(route, "properties", "$.properties.route.properties"),
         {:ok, result_values} <- validate_result_schema(properties["result"]),
         :ok <- validate_handoff_schema(properties["handoff"]) do
      {:ok, %{result_values: MapSet.new(result_values)}}
    end
  end

  def validate_predecessor_schema(_schema),
    do: {:error, error(:route_input_invalid, "$", "predecessor schema must be an object")}

  @doc """
  Merges the result enum declarations from all legal incoming predecessors.
  """
  @spec derive_type_environment([map()]) :: {:ok, type_environment()} | {:error, error()}
  def derive_type_environment(schemas) when is_list(schemas) and schemas != [] do
    schemas
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {schema, index}, {:ok, result_values} ->
      case validate_predecessor_schema(schema) do
        {:ok, %{result_values: declared_values}} ->
          {:cont, {:ok, MapSet.union(result_values, declared_values)}}

        {:error, %{path: path} = reason} ->
          {:halt, {:error, %{reason | path: "$.predecessors[#{index}]#{drop_root(path)}"}}}
      end
    end)
    |> case do
      {:ok, result_values} -> {:ok, %{result_values: result_values}}
      {:error, reason} -> {:error, reason}
    end
  end

  def derive_type_environment(_schemas),
    do:
      {:error, error(:route_input_invalid, "$.predecessors", "must contain at least one schema")}

  defp decode_route_output(%{"route" => %{"result" => result, "handoff" => handoff}})
       when is_binary(result) and result != "" and is_map(handoff) do
    {:ok, result, handoff}
  end

  defp decode_route_output(_output) do
    {:error,
     error(
       :route_input_invalid,
       "$.previous_output.route",
       "must contain a non-empty result string and handoff object"
     )}
  end

  defp decode_task(%{"level" => level, "tags" => tags}) do
    with :ok <- validate_level(level),
         :ok <- validate_tags(tags) do
      {:ok, %{level: level, tags: tags}}
    end
  end

  defp decode_task(_task),
    do: {:error, error(:route_input_invalid, "$.task", "must contain level and tags")}

  defp validate_level(level) when is_binary(level) do
    if MapSet.member?(@levels, level) do
      :ok
    else
      {:error, error(:route_input_invalid, "$.task.level", "must be epic, ticket, or task")}
    end
  end

  defp validate_level(_level),
    do: {:error, error(:route_input_invalid, "$.task.level", "must be a string")}

  defp validate_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1) do
      :ok
    else
      {:error, error(:route_input_invalid, "$.task.tags", "must contain only strings")}
    end
  end

  defp validate_tags(_tags),
    do: {:error, error(:route_input_invalid, "$.task.tags", "must be an array")}

  defp validate_visit_count(count) when is_integer(count) and count > 0, do: :ok

  defp validate_visit_count(_count) do
    {:error,
     error(:route_input_invalid, "$.execution.step_visit_count", "must be a positive integer")}
  end

  defp result_values(:unknown_result_values), do: {:ok, :unknown_result_values}
  defp result_values(%{result_values: %MapSet{} = result_values}), do: {:ok, result_values}

  defp result_values(result_values) when is_list(result_values) do
    if result_values != [] and Enum.all?(result_values, &(is_binary(&1) and &1 != "")) do
      {:ok, MapSet.new(result_values)}
    else
      {:error, error(:route_input_invalid, "$.result_values", "must contain non-empty strings")}
    end
  end

  defp result_values(_environment) do
    {:error, error(:route_input_invalid, "$.result_values", "must be a result enum environment")}
  end

  defp validate_rules(rules, result_values) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, &validate_rule(&1, &2, result_values))
  end

  defp validate_rules_and_default(rules, default, result_values) do
    case validate_rules(rules, result_values) do
      :ok -> validate_open_domain_default(rules, default)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_rule({rule, index}, :ok, result_values) do
    case Map.fetch(rule, :when) do
      {:ok, condition} ->
        continue_validation(condition, result_values, index)

      :error ->
        {:halt, {:error, error(:route_config_invalid, "$.rules[#{index}].when", "is required")}}
    end
  end

  defp continue_validation(condition, result_values, index) do
    case validate_expression(condition, result_values, "$.rules[#{index}].when") do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_expression(%{kind: kind, expressions: expressions}, result_values, path)
       when kind in [:all, :any] and is_list(expressions) and expressions != [] do
    expressions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {expression, index}, :ok ->
      case validate_expression(expression, result_values, "#{path}.#{kind}[#{index}]") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_expression(%{kind: :not, expression: expression}, result_values, path),
    do: validate_expression(expression, result_values, "#{path}.not")

  defp validate_expression(
         %{kind: :predicate, ref: ref, operator: operator, value: value},
         result_values,
         path
       ) do
    case validate_operator(ref, operator, path) do
      :ok -> validate_operand(ref, operator, value, result_values, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_expression(_expression, _result_values, path),
    do: {:error, error(:route_config_invalid, path, "must be a decoded expression")}

  defp validate_operator(ref, operator, path) do
    case Map.get(@operator_sets, ref) do
      nil ->
        {:error,
         error(:route_reference_unknown, "#{path}.ref", "is not a supported route reference")}

      operators ->
        if MapSet.member?(operators, operator) do
          :ok
        else
          {:error,
           error(
             :route_operand_type_mismatch,
             "#{path}.op",
             "#{inspect(operator)} is not valid for #{inspect(ref)}"
           )}
        end
    end
  end

  defp validate_operand(:previous_output_route_result, operator, value, result_values, path) do
    case string_values(operator, value, path) do
      {:ok, values} -> validate_enum_values(values, result_values, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_operand(:task_level, operator, value, _result_values, path) do
    case string_values(operator, value, path) do
      {:ok, values} -> validate_enum_values(values, @levels, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_operand(:task_tags, operator, value, _result_values, path) do
    if operator == :contains do
      validate_nonempty_string(value, "#{path}.value")
    else
      validate_nonempty_string_list(value, "#{path}.value")
    end
  end

  defp validate_operand(:execution_step_visit_count, operator, value, _result_values, path) do
    if operator == :in do
      validate_positive_integer_list(value, "#{path}.value")
    else
      validate_positive_integer(value, "#{path}.value")
    end
  end

  defp string_values(:in, value, path) do
    with :ok <- validate_nonempty_string_list(value, "#{path}.value") do
      {:ok, value}
    end
  end

  defp string_values(_operator, value, path) do
    with :ok <- validate_nonempty_string(value, "#{path}.value") do
      {:ok, [value]}
    end
  end

  defp validate_enum_values(_values, :unknown_result_values, _path), do: :ok

  defp validate_enum_values(values, allowed_values, path) do
    unknown_values = Enum.reject(values, &MapSet.member?(allowed_values, &1))

    case unknown_values do
      [] ->
        :ok

      [value | _] ->
        {:error,
         error(:route_config_invalid, "#{path}.value", "#{inspect(value)} is not declared")}
    end
  end

  defp validate_open_domain_default(rules, nil) do
    if Enum.any?(rules, &uses_open_domain?/1) do
      {:error,
       error(:route_config_invalid, "$.default", "is required for tag or visit-count rules")}
    else
      :ok
    end
  end

  defp validate_open_domain_default(_rules, _default), do: :ok

  defp uses_open_domain?(%{when: condition}), do: uses_open_domain_expression?(condition)
  defp uses_open_domain?(_rule), do: false

  defp uses_open_domain_expression?(%{kind: kind, expressions: expressions})
       when kind in [:all, :any],
       do: Enum.any?(expressions, &uses_open_domain_expression?/1)

  defp uses_open_domain_expression?(%{kind: :not, expression: expression}),
    do: uses_open_domain_expression?(expression)

  defp uses_open_domain_expression?(%{kind: :predicate, ref: ref}),
    do: ref in [:task_tags, :execution_step_visit_count]

  defp uses_open_domain_expression?(_expression), do: false

  defp require_route_property(schema) do
    with {:ok, properties} <- fetch_map(schema, "properties", "$.properties"),
         :ok <- require_keys(schema["required"], ["route"], "$.required"),
         true <- Map.has_key?(properties, "route") do
      :ok
    else
      false -> {:error, error(:route_input_invalid, "$.properties.route", "is required")}
      {:error, reason} -> {:error, reason}
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
    case WorkflowStep.validate_codex_strict_schema(handoff) do
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

  defp fetch_map(map, key, path) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, error(:route_input_invalid, path, "must be an object")}
    end
  end

  defp fetch_map(_map, _key, path),
    do: {:error, error(:route_input_invalid, path, "must be an object")}

  defp require_exact_value(map, key, expected, path) when is_map(map) do
    if Map.get(map, key) == expected do
      :ok
    else
      {:error, error(:route_input_invalid, path, "must be #{inspect(expected)}")}
    end
  end

  defp require_keys(keys, required, path) when is_list(keys) do
    if Enum.all?(required, &(&1 in keys)) do
      :ok
    else
      {:error, error(:route_input_invalid, path, "must include #{Enum.join(required, ", ")}")}
    end
  end

  defp require_keys(_keys, _required, path),
    do: {:error, error(:route_input_invalid, path, "must be an array")}

  defp validate_nonempty_string(value, _path) when is_binary(value) and value != "", do: :ok

  defp validate_nonempty_string(_value, path),
    do: {:error, error(:route_operand_type_mismatch, path, "must be a non-empty string")}

  defp validate_nonempty_string_list(values, path) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and
         length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, error(:route_operand_type_mismatch, path, "must be unique non-empty strings")}
    end
  end

  defp validate_nonempty_string_list(_values, path),
    do: {:error, error(:route_operand_type_mismatch, path, "must be a non-empty array")}

  defp validate_positive_integer(value, _path) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(_value, path),
    do: {:error, error(:route_operand_type_mismatch, path, "must be a positive integer")}

  defp validate_positive_integer_list(values, path) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)) and
         length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, error(:route_operand_type_mismatch, path, "must be unique positive integers")}
    end
  end

  defp validate_positive_integer_list(_values, path),
    do: {:error, error(:route_operand_type_mismatch, path, "must be a non-empty array")}

  defp drop_root("$"), do: ""
  defp drop_root(path), do: String.replace_prefix(path, "$", "")

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
