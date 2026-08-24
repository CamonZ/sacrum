defmodule Sacrum.Orchestrator.Routing.RouteConfig do
  @moduledoc """
  Decodes the closed, versioned route configuration language.

  The decoder turns untrusted JSON-shaped data into a small map-based AST. It
  never resolves database entities or turns submitted strings into atoms.
  """

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

  @type rule :: %{id: String.t(), when: expression(), transition: target()}
  @type t :: %{version: 1, match_policy: :exactly_one, rules: [rule()], default: target() | nil}
  @type error :: %{
          code: :route_config_invalid | :route_config_version_unsupported,
          path: String.t(),
          message: String.t()
        }

  @references %{
    "previous_output.route.result" => :previous_output_route_result,
    "task.level" => :task_level,
    "task.tags" => :task_tags,
    "execution.step_visit_count" => :execution_step_visit_count
  }

  @operators %{
    "eq" => :eq,
    "neq" => :neq,
    "in" => :in,
    "contains" => :contains,
    "contains_any" => :contains_any,
    "contains_all" => :contains_all,
    "lt" => :lt,
    "lte" => :lte,
    "gt" => :gt,
    "gte" => :gte
  }

  @rule_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  @doc """
  Decodes a V1 route configuration into a normalized, inert AST.
  """
  @spec decode(term()) :: {:ok, t()} | {:error, error()}
  def decode(config) when is_map(config) do
    with :ok <- validate_keys(config, ["version", "match_policy", "rules"], ["default"], "$"),
         :ok <- validate_version(config),
         :ok <- validate_match_policy(config),
         {:ok, rules} <- decode_rules(Map.fetch!(config, "rules")),
         {:ok, default} <- decode_default(Map.get(config, "default")) do
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
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, decoded_rules} ->
      case decode_rule(rule, "$.rules[#{index}]") do
        {:ok, decoded_rule} -> {:cont, {:ok, [decoded_rule | decoded_rules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded_rules} ->
        decoded_rules
        |> Enum.reverse()
        |> validate_unique_rule_ids()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_rules([]), do: {:error, error("$.rules", "must contain at least one rule")}
  defp decode_rules(_rules), do: {:error, error("$.rules", "must be an array")}

  defp decode_rule(rule, path) when is_map(rule) do
    with :ok <- validate_keys(rule, ["id", "when", "transition"], [], path),
         {:ok, id} <- decode_rule_id(Map.fetch!(rule, "id"), "#{path}.id"),
         {:ok, condition} <- decode_expression(Map.fetch!(rule, "when"), "#{path}.when"),
         {:ok, transition} <- decode_target(Map.fetch!(rule, "transition"), "#{path}.transition") do
      {:ok, %{id: id, when: condition, transition: transition}}
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
    expressions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {expression, index}, {:ok, decoded} ->
      case decode_expression(expression, "#{path}.#{kind}[#{index}]") do
        {:ok, decoded_expression} -> {:cont, {:ok, [decoded_expression | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, %{kind: kind, expressions: Enum.reverse(decoded)}}
      {:error, reason} -> {:error, reason}
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
         {:ok, ref} <- decode_reference(Map.fetch!(predicate, "ref"), "#{path}.ref"),
         {:ok, operator} <- decode_operator(Map.fetch!(predicate, "op"), "#{path}.op") do
      {:ok,
       %{kind: :predicate, ref: ref, operator: operator, value: Map.fetch!(predicate, "value")}}
    end
  end

  defp decode_reference(reference, path) when is_binary(reference) do
    case Map.fetch(@references, reference) do
      {:ok, normalized_reference} -> {:ok, normalized_reference}
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

  defp decode_default(nil), do: {:ok, nil}

  defp decode_default(default) when is_map(default) do
    with :ok <- validate_keys(default, ["transition"], [], "$.default") do
      decode_target(Map.fetch!(default, "transition"), "$.default.transition")
    end
  end

  defp decode_default(_default), do: {:error, error("$.default", "must be an object")}

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
