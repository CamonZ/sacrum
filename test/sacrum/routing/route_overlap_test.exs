defmodule Sacrum.Routing.RouteOverlapTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep.Config.StructuredInference
  alias Sacrum.Routing.{RouteConfig, RouteOverlap, RoutePredecessors}

  @step_id "00000000-0000-0000-0000-000000000001"

  describe "numeric thresholds" do
    test "rejects overlapping compound threshold rules with a clamped witness" do
      assert {:error, %{code: :route_config_ambiguous, path: "$.rules[1].when", message: message}} =
               analyze(judge(), [
                 all([level("epic"), p("approved.probabilities.yes", "gte", 0.8)]),
                 all([level("epic"), p("approved.confidence", "gte", 0.5)])
               ])

      assert message ==
               ~s(overlaps rule "r0" for task.level="epic", approved.probabilities.yes in [0.8, 1], ) <>
                 "approved.confidence in [0.5, 1]"
    end

    test "accepts disjoint thresholds" do
      assert :ok =
               analyze(judge(), [
                 p("approved.confidence", "gte", 0.8),
                 p("approved.confidence", "lt", 0.8)
               ])
    end

    test "closed bounds overlap at the boundary and open bounds do not" do
      assert {:error, %{message: message}} =
               analyze(judge(), [
                 p("approved.confidence", "gte", 0.8),
                 p("approved.confidence", "lte", 0.8)
               ])

      assert message =~ "approved.confidence=0.8"

      assert :ok =
               analyze(judge(), [
                 p("approved.confidence", "gt", 0.8),
                 p("approved.confidence", "lt", 0.8)
               ])
    end

    test "applies schema bounds: an empty range overlaps nothing" do
      assert :ok =
               analyze(judge(), [
                 p("quality.score", "gt", 2),
                 p("quality.score", "gte", 1)
               ])

      assert {:error, %{message: message}} =
               analyze(judge(), [
                 p("quality.score", "gt", 1),
                 p("quality.score", "gte", 1)
               ])

      assert message =~ "quality.score in (1, 2]"
    end

    test "neq splits a numeric range" do
      assert :ok =
               analyze(judge(), [
                 p("risk.noul", "eq", 0.5),
                 p("risk.noul", "neq", 0.5)
               ])
    end
  end

  describe "finite and mixed references" do
    test "different choices are disjoint regardless of numeric predicates" do
      assert :ok =
               analyze(judge(), [
                 all([p("approved.choice", "eq", "yes"), p("approved.confidence", "gte", 0.1)]),
                 all([p("approved.choice", "eq", "no"), p("approved.confidence", "gte", 0.1)])
               ])
    end

    test "a choice rule overlaps a threshold rule on another reference" do
      assert {:error, %{message: message}} =
               analyze(judge(), [
                 p("approved.choice", "eq", "yes"),
                 p("approved.confidence", "gte", 0.7)
               ])

      assert message ==
               ~s(overlaps rule "r0" for approved.choice="yes", approved.confidence in [0.7, 1])
    end

    test "a plain level rule overlaps a compound rule with the same level only" do
      assert {:error, %{path: "$.rules[1].when"}} =
               analyze(judge(), [
                 level("epic"),
                 all([level("epic"), p("approved.confidence", "gte", 0.5)])
               ])

      assert :ok =
               analyze(judge(), [
                 level("ticket"),
                 all([level("epic"), p("approved.confidence", "gte", 0.5)])
               ])
    end

    test "integer eq and in overlap" do
      assert {:error, %{message: message}} =
               analyze(typed(), [p("attempts", "eq", 2), p("attempts", "in", [1, 2])])

      assert message =~ "attempts=2"

      assert :ok = analyze(typed(), [p("attempts", "lt", 3), p("attempts", "gt", 2)])
      assert :ok = analyze(typed(), [p("attempts", "neq", 1), p("attempts", "in", [1])])
    end

    test "integer and float operands compare exactly" do
      assert {:error, %{message: message}} =
               analyze(judge(), [p("quality.score", "in", [1]), p("quality.score", "in", [1.0])])

      assert message =~ "quality.score=1"

      assert :ok =
               analyze(judge(), [p("quality.score", "gt", 1.0), p("quality.score", "lte", 1)])
    end

    test "boolean eq overlaps" do
      assert {:error, %{message: message}} =
               analyze(typed(), [p("flagged", "eq", true), p("flagged", "neq", false)])

      assert message =~ "flagged=true"

      assert :ok = analyze(typed(), [p("flagged", "eq", true), p("flagged", "eq", false)])
    end

    test "open strings are co-finite" do
      assert {:error, _reason} =
               analyze(typed(), [p("note", "neq", "a"), p("note", "neq", "b")])

      assert :ok = analyze(typed(), [p("note", "eq", "a"), p("note", "neq", "a")])
    end
  end

  test "reports an overlap only one of several predecessors admits" do
    narrow = structured(%{"quality" => score_question(3)}, "narrow")
    wide = structured(%{"quality" => score_question(6)}, "wide")

    rules = [p("quality.score", "gt", 2), p("quality.score", "gte", 1)]

    assert :ok = analyze([narrow], rules)

    assert {:error, %{message: message}} = analyze([narrow, wide], rules)
    assert message =~ "quality.score in (2, 5]"
  end

  describe "shapes" do
    test "any and not are normalized exactly" do
      assert :ok =
               analyze(judge(), [
                 any([p("approved.confidence", "lt", 0.2), p("risk.noul", "lt", 0.2)]),
                 all([
                   not_(p("approved.confidence", "lt", 0.2)),
                   not_(p("risk.noul", "lt", 0.2))
                 ])
               ])

      assert :ok =
               analyze(judge(), [
                 not_(any([level("epic"), p("approved.confidence", "gte", 0.5)])),
                 any([level("epic"), p("approved.confidence", "gte", 0.5)])
               ])
    end

    test "an alternative without tags still overlaps" do
      assert {:error, %{path: "$.rules[1].when", message: message}} =
               analyze(judge(), [any([level("epic"), tags("x")]), level("epic")])

      assert message == ~s(overlaps rule "r0" for task.level="epic")
    end

    test "tag and visit-count conjunctions are never reported" do
      assert :ok =
               analyze(judge(), [
                 all([level("epic"), tags("x")]),
                 all([level("epic"), visits(2)])
               ])

      assert :ok =
               analyze(judge(), [
                 all([level("epic"), not_(tags("x"))]),
                 level("epic")
               ])
    end
  end

  defp analyze(predecessors, whens) do
    {:ok, environment} = RoutePredecessors.derive_type_environment(predecessors)

    rules =
      whens
      |> Enum.with_index()
      |> Enum.map(fn {condition, index} ->
        %{"id" => "r#{index}", "when" => condition, "transition" => target()}
      end)

    {:ok, program} =
      RouteConfig.decode(%{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => rules,
        "default" => %{"transition" => target()}
      })

    :ok = RoutePredecessors.validate(program, environment)
    RouteOverlap.validate(program, environment)
  end

  defp judge do
    [
      structured(%{
        "approved" => %{
          "type" => "choice",
          "instructions" => "Are the requirements met?",
          "criteria" => %{"yes" => nil, "no" => nil}
        },
        "quality" => score_question(3),
        "risk" => %{"type" => "noul", "instructions" => "Is it risky?"}
      })
    ]
  end

  defp score_question(levels) do
    %{
      "type" => "score",
      "instructions" => "How good is it?",
      "criteria" => Enum.map(1..levels, &"level #{&1}")
    }
  end

  defp structured(questions, id \\ "judge") do
    %{
      transition_id: id,
      step_type: :structured_inference,
      output_schema: StructuredInference.answers_schema(questions)
    }
  end

  defp typed do
    [
      %{
        transition_id: "typed",
        step_type: :llm_inference,
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "attempts" => %{"type" => "integer", "minimum" => 0},
            "flagged" => %{"type" => "boolean"},
            "note" => %{"type" => "string"}
          },
          "required" => ["attempts", "flagged", "note"]
        }
      }
    ]
  end

  defp p(path, op, value), do: %{"ref" => "previous_output.#{path}", "op" => op, "value" => value}
  defp level(value), do: %{"ref" => "task.level", "op" => "eq", "value" => value}
  defp tags(tag), do: %{"ref" => "task.tags", "op" => "contains", "value" => tag}
  defp visits(count), do: %{"ref" => "execution.step_visit_count", "op" => "eq", "value" => count}
  defp all(expressions), do: %{"all" => expressions}
  defp any(expressions), do: %{"any" => expressions}
  defp not_(expression), do: %{"not" => expression}
  defp target, do: %{"type" => "intra_workflow", "step_id" => @step_id}
end
