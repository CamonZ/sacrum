defmodule Sacrum.Routing.RouteEvaluatorTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.{RouteConfig, RouteContext, RouteEvaluator}

  @step_id "00000000-0000-0000-0000-000000000001"
  @workflow_id "00000000-0000-0000-0000-000000000002"

  test "selects a result and level rule with no handoff when its decision omits one" do
    program =
      program([
        rule("approved-epic", %{
          "all" => [
            predicate("previous_output.route.result", "eq", "approved"),
            predicate("task.level", "eq", "epic")
          ]
        })
      ])

    context = context("approved", "epic", [], 1, %{"note" => "evidence"})

    assert {:ok, result} = RouteEvaluator.evaluate(program, context)
    assert result.matched_rule_id == "approved-epic"
    refute result.used_default
    assert result.transition == %{type: :intra_workflow, step_id: @step_id}
    assert result.handoff == nil
  end

  test "selects and renders a rule-specific handoff template" do
    program =
      program([
        rule(
          "approved",
          predicate("previous_output.route.result", "eq", "approved"),
          %{
            "review" => "{{ previous_output.route.handoff.review }}",
            "level" => "{{ task.level }}",
            "visit" => "{{ execution.step_visit_count }}"
          }
        )
      ])

    assert {:ok, result} =
             RouteEvaluator.evaluate(
               program,
               context("approved", "ticket", [], 3, %{"review" => "needed"})
             )

    assert result.matched_rule_id == "approved"
    assert result.handoff == %{"review" => "needed", "level" => "ticket", "visit" => 3}
  end

  test "selects and renders the default handoff template" do
    program =
      program(
        [rule("approved", predicate("previous_output.route.result", "eq", "approved"))],
        default(%{"tags" => "{{ task.tags }}", "fallback" => true})
      )

    assert {:ok, result} =
             RouteEvaluator.evaluate(program, context("rejected", "task", ["triage"], 1))

    assert result.matched_rule_id == nil
    assert result.used_default
    assert result.handoff == %{"tags" => ["triage"], "fallback" => true}
  end

  test "evaluates tag and visit-count predicates with nested composition" do
    program =
      program([
        rule("bounded-backend-retry", %{
          "all" => [
            predicate("task.tags", "contains_all", ["backend", "urgent"]),
            %{
              "any" => [
                predicate("execution.step_visit_count", "lte", 3),
                %{"not" => predicate("previous_output.route.result", "eq", "retry")}
              ]
            }
          ]
        })
      ])

    assert {:ok, %{matched_rule_id: "bounded-backend-retry"}} =
             RouteEvaluator.evaluate(program, context("retry", "task", ["backend", "urgent"], 3))
  end

  test "evaluates each whitelisted predicate family" do
    context = context("approved", "ticket", ["backend", "urgent"], 3)

    cases = [
      {"result", "previous_output.route.result", "in", ["approved"], true},
      {"level", "task.level", "neq", "epic", true},
      {"tags", "task.tags", "contains", "backend", true},
      {"tags", "task.tags", "contains_any", ["other", "urgent"], true},
      {"tags", "task.tags", "contains_all", ["backend", "urgent"], true},
      {"count", "execution.step_visit_count", "eq", 3, true},
      {"count", "execution.step_visit_count", "neq", 2, true},
      {"count", "execution.step_visit_count", "lt", 4, true},
      {"count", "execution.step_visit_count", "lte", 3, true},
      {"count", "execution.step_visit_count", "gt", 2, true},
      {"count", "execution.step_visit_count", "gte", 3, true},
      {"count", "execution.step_visit_count", "in", [1, 3], true},
      {"count", "execution.step_visit_count", "lt", 3, false}
    ]

    for {family, reference, operator, value, matches?} <- cases do
      program = program([rule("#{family}-#{operator}", predicate(reference, operator, value))])

      assert {:ok, result} = RouteEvaluator.evaluate(program, context)
      assert result.matched_rule_id == if(matches?, do: "#{family}-#{operator}", else: nil)
      assert result.used_default == !matches?
    end
  end

  test "uses the explicit default when no rule matches" do
    program =
      program(
        [rule("approved", predicate("previous_output.route.result", "eq", "approved"))],
        default()
      )

    assert {:ok, result} = RouteEvaluator.evaluate(program, context("rejected", "task", [], 1))
    assert result.matched_rule_id == nil
    assert result.used_default
    assert result.transition == %{type: :inter_workflow, workflow_id: @workflow_id}
  end

  test "returns a stable no-match error without a default" do
    program =
      program(
        [rule("approved", predicate("previous_output.route.result", "eq", "approved"))],
        nil
      )

    assert {:error, %{code: :route_no_match}} =
             RouteEvaluator.evaluate(program, context("rejected", "task", [], 1))
  end

  test "returns a stable ambiguity error instead of using rule order" do
    program =
      program([
        rule("approved", predicate("previous_output.route.result", "eq", "approved")),
        rule("epic", predicate("task.level", "eq", "epic"))
      ])

    assert {:error, %{code: :route_ambiguous_match}} =
             RouteEvaluator.evaluate(program, context("approved", "epic", [], 1))
  end

  test "is deterministic across repeated evaluations" do
    program =
      program([rule("approved", predicate("previous_output.route.result", "eq", "approved"))])

    context = context("approved", "task", [], 1)

    assert [result, result, result] =
             Enum.map(1..3, fn _attempt -> RouteEvaluator.evaluate(program, context) end)
  end

  defp program(rules, default \\ default()) do
    {:ok, decoded} =
      RouteConfig.decode(%{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => rules,
        "default" => default
      })

    decoded
  end

  defp rule(id, when_expression, handoff \\ nil) do
    rule = %{
      "id" => id,
      "when" => when_expression,
      "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
    }

    if is_nil(handoff), do: rule, else: Map.put(rule, "handoff", handoff)
  end

  defp predicate(reference, operator, value),
    do: %{"ref" => reference, "op" => operator, "value" => value}

  defp default(handoff \\ nil) do
    decision = %{"transition" => %{"type" => "inter_workflow", "workflow_id" => @workflow_id}}

    if is_nil(handoff), do: decision, else: Map.put(decision, "handoff", handoff)
  end

  defp context(result, level, tags, count, handoff \\ %{"note" => "ready"}) do
    {:ok, route_context} =
      RouteContext.build(
        %{"route" => %{"result" => result, "handoff" => handoff}},
        %{"level" => level, "tags" => tags},
        count
      )

    route_context
  end
end
