defmodule Sacrum.Routing.RouteEvaluator do
  @moduledoc """
  Pure evaluator for validated deterministic route programs.

  Evaluation reads only a decoded `RouteConfig` and a `RouteContext`. It has
  no repository, clock, prompt, daemon, or random dependencies.
  """

  alias Sacrum.Routing.{HandoffTemplate, RouteConfig, RouteContext, Traverse}

  @type result :: %{
          matched_rule_id: String.t() | nil,
          used_default: boolean(),
          transition: map(),
          handoff: map() | nil
        }

  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Selects exactly one matching rule, or the explicit default when no rules
  match, then renders only that decision's handoff template.
  """
  @spec evaluate(RouteConfig.t(), RouteContext.t()) :: {:ok, result()} | {:error, error()}
  def evaluate(%{rules: rules, default: default}, context) do
    with {:ok, matching_rules} <- matching_rules(rules, context) do
      select_result(matching_rules, default, context)
    end
  end

  @doc """
  Returns every matching rule ID without applying the exactly-one policy.

  Static validation uses this shared predicate evaluator to prove ambiguity for
  finite domains. Runtime route selection remains owned by `evaluate/2`.
  """
  @spec matching_rule_ids(RouteConfig.t(), RouteContext.t()) ::
          {:ok, [String.t()]} | {:error, error()}
  def matching_rule_ids(%{rules: rules}, context) do
    with {:ok, matching_rules} <- matching_rules(rules, context) do
      {:ok, for({%{id: id}, _index} <- matching_rules, do: id)}
    end
  end

  defp matching_rules(rules, context) do
    case Traverse.map_while(rules, &match_rule(&1, context, &2)) do
      {:ok, matches} -> {:ok, for({true, rule, index} <- matches, do: {rule, index})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_rule(rule, context, index) do
    with {:ok, matched?} <- rule_matches?(rule, context, "$.rules[#{index}]") do
      {:ok, {matched?, rule, index}}
    end
  end

  defp rule_matches?(%{when: expression}, context, path),
    do: evaluate_expression(expression, context, "#{path}.when")

  defp select_result([{rule, index}], _default, context) do
    render_decision(rule, context, "$.rules[#{index}].handoff", rule.id, false)
  end

  defp select_result([], %{transition: _, handoff: _} = decision, context) do
    render_decision(decision, context, "$.default.handoff", nil, true)
  end

  defp select_result([], _default, _context),
    do:
      {:error,
       error(:route_no_match, "$.rules", "no route rule matched and no default is configured")}

  defp select_result(_matches, _default, _context) do
    {:error, error(:route_ambiguous_match, "$.rules", "more than one route rule matched")}
  end

  defp render_decision(
         %{transition: transition, handoff: template},
         context,
         path,
         matched_rule_id,
         used_default
       ) do
    with {:ok, handoff} <- HandoffTemplate.render(template, context, path) do
      {:ok,
       %{
         matched_rule_id: matched_rule_id,
         used_default: used_default,
         transition: transition,
         handoff: handoff
       }}
    end
  end

  defp evaluate_expression(%{kind: kind, expressions: expressions}, context, path)
       when kind in [:all, :any] do
    with {:ok, results} <-
           Traverse.map_while(expressions, fn expression, index ->
             evaluate_expression(expression, context, "#{path}.#{kind}[#{index}]")
           end) do
      {:ok, if(kind == :all, do: Enum.all?(results), else: Enum.any?(results))}
    end
  end

  defp evaluate_expression(%{kind: :not, expression: expression}, context, path) do
    with {:ok, result} <- evaluate_expression(expression, context, "#{path}.not"),
         do: {:ok, not result}
  end

  defp evaluate_expression(
         %{kind: :predicate, ref: reference, operator: operator, value: expected},
         context,
         path
       ) do
    with {:ok, actual} <- fetch_reference(context, reference, path) do
      {:ok, predicate(operator, actual, expected)}
    end
  end

  defp fetch_reference(context, reference, path) do
    case RouteContext.fetch(context, reference) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, %{reason | path: "#{path}.ref"}}
    end
  end

  defp predicate(:eq, actual, expected), do: actual == expected
  defp predicate(:neq, actual, expected), do: actual != expected
  defp predicate(:in, actual, expected), do: actual in expected
  defp predicate(:contains, tags, expected), do: expected in tags
  defp predicate(:contains_any, tags, expected), do: Enum.any?(expected, &(&1 in tags))
  defp predicate(:contains_all, tags, expected), do: Enum.all?(expected, &(&1 in tags))
  defp predicate(:lt, actual, expected), do: actual < expected
  defp predicate(:lte, actual, expected), do: actual <= expected
  defp predicate(:gt, actual, expected), do: actual > expected
  defp predicate(:gte, actual, expected), do: actual >= expected

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
