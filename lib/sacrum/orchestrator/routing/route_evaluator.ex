defmodule Sacrum.Orchestrator.Routing.RouteEvaluator do
  @moduledoc """
  Pure evaluator for validated deterministic route programs.

  Evaluation reads only a `RouteContext` and decoded routing AST. It has no
  repository, clock, prompt, daemon, or random dependencies.
  """

  alias Sacrum.Orchestrator.Routing.RouteContext

  @type result :: %{
          matched_rule_id: String.t() | nil,
          used_default: boolean(),
          transition: map(),
          handoff: map()
        }

  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Selects exactly one matching rule, or the explicit default when no rules
  match, and returns the predecessor handoff unchanged.
  """
  @spec evaluate(map(), RouteContext.t()) :: {:ok, result()} | {:error, error()}
  def evaluate(%{rules: rules, default: default}, context)
      when is_list(rules) and is_map(context) do
    with {:ok, handoff} <- fetch_handoff(context),
         {:ok, matching_rules} <- matching_rules(rules, context) do
      select_result(matching_rules, default, handoff)
    end
  end

  def evaluate(_program, _context),
    do:
      {:error,
       error(:route_config_invalid, "$", "must be a decoded route program and RouteContext")}

  defp matching_rules(rules, context) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule, index}, {:ok, matches} ->
      case rule_matches?(rule, context, "$.rules[#{index}]") do
        {:ok, true} -> {:cont, {:ok, [rule | matches]}}
        {:ok, false} -> {:cont, {:ok, matches}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, matches} -> {:ok, Enum.reverse(matches)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rule_matches?(%{when: expression}, context, path),
    do: evaluate_expression(expression, context, "#{path}.when")

  defp rule_matches?(_rule, _context, path),
    do: {:error, error(:route_config_invalid, "#{path}.when", "is required")}

  defp select_result([%{id: id, transition: transition}], _default, handoff) do
    {:ok, %{matched_rule_id: id, used_default: false, transition: transition, handoff: handoff}}
  end

  defp select_result([], default, handoff) when is_map(default) do
    {:ok, %{matched_rule_id: nil, used_default: true, transition: default, handoff: handoff}}
  end

  defp select_result([], _default, _handoff),
    do:
      {:error,
       error(:route_no_match, "$.rules", "no route rule matched and no default is configured")}

  defp select_result(_matches, _default, _handoff) do
    {:error, error(:route_ambiguous_match, "$.rules", "more than one route rule matched")}
  end

  defp evaluate_expression(%{kind: :all, expressions: expressions}, context, path)
       when is_list(expressions) do
    with {:ok, results} <- evaluate_expressions(expressions, context, "#{path}.all") do
      {:ok, Enum.all?(results)}
    end
  end

  defp evaluate_expression(%{kind: :any, expressions: expressions}, context, path)
       when is_list(expressions) do
    with {:ok, results} <- evaluate_expressions(expressions, context, "#{path}.any") do
      {:ok, Enum.any?(results)}
    end
  end

  defp evaluate_expression(%{kind: :not, expression: expression}, context, path) do
    with {:ok, result} <- evaluate_expression(expression, context, "#{path}.not") do
      {:ok, not result}
    end
  end

  defp evaluate_expression(
         %{kind: :predicate, ref: ref, operator: operator, value: expected},
         context,
         path
       ) do
    with {:ok, actual} <- fetch_reference(context, ref, path) do
      evaluate_predicate(ref, operator, actual, expected, path)
    end
  end

  defp evaluate_expression(_expression, _context, path),
    do: {:error, error(:route_config_invalid, path, "must be a decoded expression")}

  defp evaluate_expressions(expressions, context, path) do
    expressions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {expression, index}, {:ok, results} ->
      case evaluate_expression(expression, context, "#{path}[#{index}]") do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_handoff(context) do
    case get_in(context, [:previous_output, :route, :handoff]) do
      handoff when is_map(handoff) ->
        {:ok, handoff}

      _ ->
        {:error,
         error(:route_reference_missing, "$.previous_output.route.handoff", "is required")}
    end
  end

  defp fetch_reference(context, reference, path) do
    case RouteContext.fetch(context, reference) do
      {:ok, nil} -> {:error, error(:route_reference_missing, "#{path}.ref", "is missing")}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, %{reason | path: "#{path}.ref"}}
    end
  end

  defp evaluate_predicate(:previous_output_route_result, operator, actual, expected, path)
       when is_binary(actual) do
    compare_string(operator, actual, expected, path)
  end

  defp evaluate_predicate(:task_level, operator, actual, expected, path) when is_binary(actual) do
    compare_string(operator, actual, expected, path)
  end

  defp evaluate_predicate(:task_tags, :contains, actual, expected, path) when is_list(actual) do
    compare_tags(:contains, actual, expected, path)
  end

  defp evaluate_predicate(:task_tags, operator, actual, expected, path) when is_list(actual) do
    compare_tags(operator, actual, expected, path)
  end

  defp evaluate_predicate(:execution_step_visit_count, operator, actual, expected, path)
       when is_integer(actual) do
    compare_integer(operator, actual, expected, path)
  end

  defp evaluate_predicate(_ref, _operator, _actual, _expected, path) do
    {:error, error(:route_operand_type_mismatch, path, "does not match the reference type")}
  end

  defp compare_string(operator, actual, expected, _path)
       when operator in [:eq, :neq] and is_binary(expected) do
    result = if operator == :eq, do: actual == expected, else: actual != expected
    {:ok, result}
  end

  defp compare_string(:in, actual, expected, path) when is_list(expected) do
    if binary_list?(expected) do
      {:ok, actual in expected}
    else
      {:error, error(:route_operand_type_mismatch, "#{path}.value", "must be a string array")}
    end
  end

  defp compare_string(_operator, _actual, _expected, path),
    do:
      {:error,
       error(:route_operand_type_mismatch, "#{path}.value", "must be a compatible string value")}

  defp compare_tags(:contains, tags, expected, _path) when is_binary(expected),
    do: {:ok, expected in tags}

  defp compare_tags(:contains_any, tags, expected, path) when is_list(expected) do
    if binary_list?(expected) do
      {:ok, Enum.any?(expected, &(&1 in tags))}
    else
      {:error, error(:route_operand_type_mismatch, "#{path}.value", "must be a string array")}
    end
  end

  defp compare_tags(:contains_all, tags, expected, path) when is_list(expected) do
    if binary_list?(expected) do
      {:ok, Enum.all?(expected, &(&1 in tags))}
    else
      {:error, error(:route_operand_type_mismatch, "#{path}.value", "must be a string array")}
    end
  end

  defp compare_tags(_operator, _tags, _expected, path),
    do:
      {:error,
       error(:route_operand_type_mismatch, "#{path}.value", "must be compatible with task tags")}

  defp compare_integer(:in, actual, expected, path) when is_list(expected) do
    if integer_list?(expected) do
      {:ok, actual in expected}
    else
      {:error, error(:route_operand_type_mismatch, "#{path}.value", "must be an integer array")}
    end
  end

  defp compare_integer(operator, actual, expected, _path)
       when operator in [:eq, :neq, :lt, :lte, :gt, :gte] and is_integer(expected) do
    {:ok,
     case operator do
       :eq -> actual == expected
       :neq -> actual != expected
       :lt -> actual < expected
       :lte -> actual <= expected
       :gt -> actual > expected
       :gte -> actual >= expected
     end}
  end

  defp compare_integer(_operator, _actual, _expected, path) do
    {:error,
     error(:route_operand_type_mismatch, "#{path}.value", "must be a compatible integer value")}
  end

  defp binary_list?(values), do: Enum.all?(values, &is_binary/1)
  defp integer_list?(values), do: Enum.all?(values, &is_integer/1)

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
