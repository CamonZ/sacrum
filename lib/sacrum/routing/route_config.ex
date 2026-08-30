defmodule Sacrum.Routing.RouteConfig do
  @moduledoc """
  Decodes the closed, versioned route configuration language.

  The decoder turns untrusted JSON-shaped data into a small map-based AST. It
  never resolves database entities or turns submitted strings into atoms.
  """

  alias Sacrum.Routing.{HandoffTemplate, Traverse}

  @type target ::
          %{type: :intra_workflow, step_id: String.t()}
          | %{type: :inter_workflow, workflow_id: String.t()}

  @type expression ::
          %{kind: :all | :any, expressions: [expression()]}
          | %{kind: :not, expression: expression()}
          | %{
              kind: :predicate,
              ref:
                :previous_output_route_result
                | :task_level
                | :task_tags
                | :execution_step_visit_count,
              operator:
                :eq
                | :neq
                | :in
                | :contains
                | :contains_any
                | :contains_all
                | :lt
                | :lte
                | :gt
                | :gte,
              value: term()
            }

  @type handoff_template :: map() | nil
  @type decision :: %{transition: target(), handoff: handoff_template()}
  @type rule :: %{
          id: String.t(),
          when: expression(),
          transition: target(),
          handoff: handoff_template()
        }
  @type t :: %{version: 1, match_policy: :exactly_one, rules: [rule()], default: decision() | nil}
  @type error :: %{
          code:
            :route_config_invalid
            | :route_config_version_unsupported
            | :route_operand_type_mismatch,
          path: String.t(),
          message: String.t()
        }

  @references %{
    "previous_output.route.result" => %{
      atom: :previous_output_route_result,
      operators: [:eq, :neq, :in],
      value: :string,
      open?: false
    },
    "task.level" => %{
      atom: :task_level,
      operators: [:eq, :neq, :in],
      value: :level,
      open?: false
    },
    "task.tags" => %{
      atom: :task_tags,
      operators: [:contains, :contains_any, :contains_all],
      value: :tags,
      open?: true
    },
    "execution.step_visit_count" => %{
      atom: :execution_step_visit_count,
      operators: [:eq, :neq, :lt, :lte, :gt, :gte, :in],
      value: :count,
      open?: true
    }
  }

  @operators Map.new(
               [:eq, :neq, :in, :contains, :contains_any, :contains_all, :lt, :lte, :gt, :gte],
               &{Atom.to_string(&1), &1}
             )

  @levels MapSet.new(["epic", "ticket", "task"])

  @rule_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  The closed set of task levels routable by rule predicates.

  Shared with static validation so coverage analysis enumerates exactly the
  levels `task.level` predicates can observe.
  """
  @spec levels() :: [String.t()]
  def levels, do: Enum.sort(@levels)

  @doc """
  Decodes a V1 route configuration into a normalized, inert AST.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, error()}
  def decode(config) when is_map(config) do
    with :ok <- validate_keys(config, ["version", "match_policy", "rules"], ["default"], "$"),
         :ok <- validate_version(config),
         :ok <- validate_match_policy(config),
         {:ok, rules} <- decode_rules(Map.fetch!(config, "rules")),
         {:ok, default} <- decode_default(Map.get(config, "default")),
         :ok <- validate_default(rules, default) do
      {:ok, %{version: 1, match_policy: :exactly_one, rules: rules, default: default}}
    end
  end

  def decode(_config), do: {:error, error("$", "must be an object")}

  defp validate_version(%{"version" => 1}), do: :ok

  defp validate_version(_config) do
    {:error, error("$.version", "only version 1 is supported", :route_config_version_unsupported)}
  end

  defp validate_match_policy(%{"match_policy" => "exactly_one"}), do: :ok

  defp validate_match_policy(_config),
    do: {:error, error("$.match_policy", "must be exactly_one")}

  defp decode_rules(rules) when is_list(rules) and rules != [] do
    with {:ok, decoded_rules} <-
           Traverse.map_while(rules, fn rule, index ->
             decode_rule(rule, "$.rules[#{index}]")
           end) do
      validate_unique_rule_ids(decoded_rules)
    end
  end

  defp decode_rules([]), do: {:error, error("$.rules", "must contain at least one rule")}
  defp decode_rules(_rules), do: {:error, error("$.rules", "must be an array")}

  defp decode_rule(rule, path) when is_map(rule) do
    with :ok <- validate_keys(rule, ["id", "when", "transition"], ["handoff"], path),
         {:ok, id} <- decode_rule_id(Map.fetch!(rule, "id"), "#{path}.id"),
         {:ok, condition} <- decode_expression(Map.fetch!(rule, "when"), "#{path}.when"),
         {:ok, transition} <- decode_target(Map.fetch!(rule, "transition"), "#{path}.transition"),
         {:ok, handoff} <- decode_handoff(rule, "#{path}.handoff") do
      {:ok, %{id: id, when: condition, transition: transition, handoff: handoff}}
    end
  end

  defp decode_rule(_rule, path), do: {:error, error(path, "must be an object")}

  defp decode_rule_id(id, path) when is_binary(id) and id != "" do
    if Regex.match?(@rule_id, id) do
      {:ok, id}
    else
      {:error, error(path, "must contain only letters, digits, dots, underscores, or hyphens")}
    end
  end

  defp decode_rule_id(_id, path), do: {:error, error(path, "must be a non-empty string")}

  defp decode_expression(expression, path) when is_map(expression) do
    case expression |> Map.keys() |> Enum.sort() do
      ["all"] -> decode_composition(:all, Map.fetch!(expression, "all"), path)
      ["any"] -> decode_composition(:any, Map.fetch!(expression, "any"), path)
      ["not"] -> decode_not(Map.fetch!(expression, "not"), path)
      ["op", "ref", "value"] -> decode_predicate(expression, path)
      _ -> {:error, error(path, "must be exactly one boolean expression or predicate")}
    end
  end

  defp decode_expression(_expression, path), do: {:error, error(path, "must be an object")}

  defp decode_composition(kind, expressions, path)
       when is_list(expressions) and expressions != [] do
    with {:ok, decoded} <-
           Traverse.map_while(expressions, fn expression, index ->
             decode_expression(expression, "#{path}.#{kind}[#{index}]")
           end) do
      {:ok, %{kind: kind, expressions: decoded}}
    end
  end

  defp decode_composition(kind, _expressions, path) do
    {:error, error("#{path}.#{kind}", "must be a non-empty array")}
  end

  defp decode_not(expression, path) do
    with {:ok, decoded} <- decode_expression(expression, "#{path}.not") do
      {:ok, %{kind: :not, expression: decoded}}
    end
  end

  defp decode_predicate(predicate, path) do
    with :ok <- validate_keys(predicate, ["ref", "op", "value"], [], path),
         {:ok, spec} <- decode_reference(Map.fetch!(predicate, "ref"), "#{path}.ref"),
         {:ok, operator} <- decode_operator(Map.fetch!(predicate, "op"), "#{path}.op"),
         :ok <- validate_operator(spec, operator, "#{path}.op"),
         :ok <- validate_value(spec, operator, Map.fetch!(predicate, "value"), path) do
      {:ok,
       %{
         kind: :predicate,
         ref: spec.atom,
         operator: operator,
         value: Map.fetch!(predicate, "value")
       }}
    end
  end

  defp decode_reference(reference, path) when is_binary(reference) do
    case Map.fetch(@references, reference) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, error(path, "is not a supported route reference")}
    end
  end

  defp decode_reference(_reference, path), do: {:error, error(path, "must be a string")}

  defp decode_operator(operator, path) when is_binary(operator) do
    case Map.fetch(@operators, operator) do
      {:ok, normalized_operator} -> {:ok, normalized_operator}
      :error -> {:error, error(path, "is not a supported route operator")}
    end
  end

  defp decode_operator(_operator, path), do: {:error, error(path, "must be a string")}

  defp validate_operator(%{operators: operators} = spec, operator, path) do
    if operator in operators do
      :ok
    else
      validate_operator_error(spec, operator, path)
    end
  end

  defp validate_operator_error(%{atom: atom}, operator, path) do
    {:error,
     error(
       path,
       "#{inspect(operator)} is not valid for #{inspect(atom)}",
       :route_operand_type_mismatch
     )}
  end

  defp validate_value(%{value: :string}, :in, value, path),
    do: validate_nonempty_string_list(value, "#{path}.value")

  defp validate_value(%{value: :string}, _operator, value, path),
    do: validate_nonempty_string(value, "#{path}.value")

  defp validate_value(%{value: :level}, operator, value, path) do
    case string_values(operator, value, path) do
      {:ok, values} -> validate_level_values(values, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_value(%{value: :tags}, :contains, value, path),
    do: validate_nonempty_string(value, "#{path}.value")

  defp validate_value(%{value: :tags}, _operator, value, path),
    do: validate_nonempty_string_list(value, "#{path}.value")

  defp validate_value(%{value: :count}, :in, value, path),
    do: validate_positive_integer_list(value, "#{path}.value")

  defp validate_value(%{value: :count}, _operator, value, path),
    do: validate_positive_integer(value, "#{path}.value")

  defp string_values(:in, value, path) do
    with :ok <- validate_nonempty_string_list(value, "#{path}.value"), do: {:ok, value}
  end

  defp string_values(_operator, value, path) do
    with :ok <- validate_nonempty_string(value, "#{path}.value"), do: {:ok, [value]}
  end

  defp validate_level_values(values, path) do
    case Enum.find(values, &(not MapSet.member?(@levels, &1))) do
      nil -> :ok
      value -> {:error, error("#{path}.value", "#{inspect(value)} is not a task level")}
    end
  end

  defp validate_nonempty_string(value, _path) when is_binary(value) and value != "", do: :ok

  defp validate_nonempty_string(_value, path),
    do: {:error, error(path, "must be a non-empty string", :route_operand_type_mismatch)}

  defp validate_nonempty_string_list(values, path) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and
         length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, error(path, "must be unique non-empty strings", :route_operand_type_mismatch)}
    end
  end

  defp validate_nonempty_string_list(_values, path),
    do: {:error, error(path, "must be a non-empty array", :route_operand_type_mismatch)}

  defp validate_positive_integer(value, _path) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(_value, path),
    do: {:error, error(path, "must be a positive integer", :route_operand_type_mismatch)}

  defp validate_positive_integer_list(values, path) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)) and
         length(values) == length(Enum.uniq(values)) do
      :ok
    else
      {:error, error(path, "must be unique positive integers", :route_operand_type_mismatch)}
    end
  end

  defp validate_positive_integer_list(_values, path),
    do: {:error, error(path, "must be a non-empty array", :route_operand_type_mismatch)}

  defp decode_default(nil), do: {:ok, nil}

  defp decode_default(default) when is_map(default) do
    with :ok <- validate_keys(default, ["transition"], ["handoff"], "$.default"),
         {:ok, transition} <-
           decode_target(Map.fetch!(default, "transition"), "$.default.transition"),
         {:ok, handoff} <- decode_handoff(default, "$.default.handoff") do
      {:ok, %{transition: transition, handoff: handoff}}
    end
  end

  defp decode_default(_default), do: {:error, error("$.default", "must be an object")}

  defp validate_default(rules, nil) do
    if Enum.any?(rules, &uses_open_domain?/1) do
      {:error,
       error("$.default", "is required for tag or visit-count rules", :route_config_invalid)}
    else
      :ok
    end
  end

  defp validate_default(_rules, _default), do: :ok

  defp decode_handoff(decision, path) do
    case Map.fetch(decision, "handoff") do
      {:ok, handoff} -> HandoffTemplate.decode(handoff, path)
      :error -> {:ok, nil}
    end
  end

  defp uses_open_domain?(%{when: condition}), do: uses_open_domain_expression?(condition)

  defp uses_open_domain_expression?(%{kind: kind, expressions: expressions})
       when kind in [:all, :any],
       do: Enum.any?(expressions, &uses_open_domain_expression?/1)

  defp uses_open_domain_expression?(%{kind: :not, expression: expression}),
    do: uses_open_domain_expression?(expression)

  defp uses_open_domain_expression?(%{kind: :predicate, ref: ref}) do
    Enum.any?(@references, fn {_key, spec} -> spec.atom == ref and spec.open? end)
  end

  defp decode_target(target, path) when is_map(target) do
    case Map.get(target, "type") do
      "intra_workflow" -> decode_intra_workflow_target(target, path)
      "inter_workflow" -> decode_inter_workflow_target(target, path)
      _ -> {:error, error("#{path}.type", "must be intra_workflow or inter_workflow")}
    end
  end

  defp decode_target(_target, path), do: {:error, error(path, "must be an object")}

  defp decode_intra_workflow_target(target, path) do
    with :ok <- validate_keys(target, ["type", "step_id"], [], path),
         {:ok, step_id} <- decode_uuid(Map.fetch!(target, "step_id"), "#{path}.step_id") do
      {:ok, %{type: :intra_workflow, step_id: step_id}}
    end
  end

  defp decode_inter_workflow_target(target, path) do
    with :ok <- validate_keys(target, ["type", "workflow_id"], [], path),
         {:ok, workflow_id} <-
           decode_uuid(Map.fetch!(target, "workflow_id"), "#{path}.workflow_id") do
      {:ok, %{type: :inter_workflow, workflow_id: workflow_id}}
    end
  end

  defp decode_uuid(value, path) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error(path, "must be a UUID")}
    end
  end

  defp decode_uuid(_value, path), do: {:error, error(path, "must be a UUID")}

  defp validate_unique_rule_ids(rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {%{id: id}, index}, {:ok, ids} ->
      if MapSet.member?(ids, id) do
        {:halt, {:error, error("$.rules[#{index}].id", "must be unique")}}
      else
        {:cont, {:ok, MapSet.put(ids, id)}}
      end
    end)
    |> case do
      {:ok, _ids} -> {:ok, rules}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_keys(value, required, optional, path) when is_map(value) do
    keys = Map.keys(value)
    allowed = required ++ optional
    missing = required -- keys
    unknown = keys -- allowed

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        {:error, error(path, "must use string keys")}

      missing != [] ->
        {:error, error("#{path}.#{hd(missing)}", "is required")}

      unknown != [] ->
        {:error, error("#{path}.#{hd(unknown)}", "is not allowed")}

      true ->
        :ok
    end
  end

  defp error(path, message, code \\ :route_config_invalid),
    do: %{code: code, path: path, message: message}
end
