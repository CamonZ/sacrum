defmodule Sacrum.Orchestrator.Routing.RouteEvaluatorTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.{RouteConfig, RouteContext, RouteEvaluator}

  @step_id "00000000-0000-0000-0000-000000000001"
  @workflow_id "00000000-0000-0000-0000-000000000002"

  test "selects a result and level rule with the original handoff" do
    program =
      program([
        rule("approved-epic", %{
          "all" => [
            predicate("previous_output.route.result", "eq", "approved"),
            predicate("task.level", "eq", "epic")
          ]
        })
      ])

    handoff = %{"note" => "evidence"}
    context = context("approved", "epic", [], 1, handoff)

    assert {:ok, result} = RouteEvaluator.evaluate(program, context)
    assert result.matched_rule_id == "approved-epic"
    refute result.used_default
    assert result.transition == %{type: :intra_workflow, step_id: @step_id}
    assert result.handoff == handoff
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

  test "defensively rejects an invalid operand type" do
    invalid_program = %{
      rules: [
        %{
          id: "bad-count",
          when: %{kind: :predicate, ref: :execution_step_visit_count, operator: :gte, value: "2"},
          transition: %{type: :intra_workflow, step_id: @step_id}
        }
      ],
      default: nil
    }

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             RouteEvaluator.evaluate(invalid_program, context("approved", "task", [], 2))
  end

  test "rejects decoded programs that fail static route validation" do
    invalid_program = %{
      rules: [
        %{
          id: "invalid-tags",
          when: %{kind: :predicate, ref: :task_tags, operator: :eq, value: "backend"},
          transition: %{type: :intra_workflow, step_id: @step_id}
        }
      ],
      default: %{type: :intra_workflow, step_id: @step_id}
    }

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.op"}} =
             RouteEvaluator.evaluate(invalid_program, context("approved", "task", [], 2))
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

  defp rule(id, when_expression) do
    %{
      "id" => id,
      "when" => when_expression,
      "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
    }
  end

  defp predicate(reference, operator, value),
    do: %{"ref" => reference, "op" => operator, "value" => value}

  defp default do
    %{"transition" => %{"type" => "inter_workflow", "workflow_id" => @workflow_id}}
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
