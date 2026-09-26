defmodule Sacrum.Routing.RoutePredecessorsTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep.Config.StructuredInference
  alias Sacrum.Routing.{RouteConfig, RoutePredecessors}

  @step_id "00000000-0000-0000-0000-000000000001"

  test "derives the result enum union from valid predecessor envelopes" do
    approved_schema = predecessor_schema(["approved"])
    rejected_schema = predecessor_schema(["rejected", "retry"])

    assert {:ok, %{result_values: result_values}} =
             RoutePredecessors.derive_type_environment([
               envelope(approved_schema, "approved"),
               envelope(rejected_schema, "rejected")
             ])

    assert result_values == MapSet.new(["approved", "rejected", "retry"])
  end

  test "rejects predecessor schemas without a result enum or strict handoff" do
    missing_enum =
      put_in(predecessor_schema(["approved"]), ["properties", "route", "properties", "result"], %{
        "type" => "string"
      })

    assert {:error, %{code: :route_input_invalid, path: "$.properties.route.properties.result"}} =
             RoutePredecessors.validate_predecessor_schema(missing_enum)

    loose_handoff =
      put_in(
        predecessor_schema(["approved"]),
        ["properties", "route", "properties", "handoff"],
        %{"type" => "object", "properties" => %{}, "required" => []}
      )

    assert {:error, %{code: :route_input_invalid, path: "$.properties.route.properties.handoff"}} =
             RoutePredecessors.validate_predecessor_schema(loose_handoff)
  end

  test "rejects predecessor result values outside their declared enum" do
    {:ok, program} =
      RouteConfig.decode(%{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "maybe",
            "when" => %{
              "ref" => "previous_output.route.result",
              "op" => "eq",
              "value" => "maybe"
            },
            "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
          }
        ]
      })

    {:ok, type_environment} =
      RoutePredecessors.derive_type_environment([envelope(predecessor_schema(["approved"]))])

    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             RoutePredecessors.validate(program, type_environment)
  end

  test "validates answer paths, labels, and operands against every predecessor" do
    {:ok, environment} = RoutePredecessors.derive_type_environment([judge()])

    assert :ok = validate_ref(environment, "previous_output.approved.choice", "eq", "yes")

    assert :ok =
             validate_ref(environment, "previous_output.approved.probabilities.yes", "gte", 0.9)

    assert :ok = validate_ref(environment, "previous_output.approved.confidence", "lt", 0.5)
    assert :ok = validate_ref(environment, "previous_output.urgency.score", "gte", 1.5)
    assert :ok = validate_ref(environment, "previous_output.urgency.probabilities.2", "gt", 0.5)
    assert :ok = validate_ref(environment, "previous_output.done.noul", "gte", 0.7)

    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.approved.choice", "eq", "maybe")

    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.approved.choice", "in", ["yes", "maybe"])

    for ref <- [
          "previous_output.missing.choice",
          "previous_output.approved.probabilities.maybe",
          "previous_output.done.confidence",
          "previous_output.approved.action.act_probability"
        ] do
      assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.ref"}} =
               validate_ref(environment, ref, "gte", 0.5)
    end

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.done.noul", "gte", "high")

    assert {:error, %{path: "$.rules[0].when.ref"}} =
             validate_ref(environment, "previous_output.route.result", "eq", "yes")

    {:ok, mixed} =
      RoutePredecessors.derive_type_environment([judge(), envelope(predecessor_schema(["yes"]))])

    assert {:error, %{path: "$.rules[0].when.ref"}} =
             validate_ref(mixed, "previous_output.approved.choice", "eq", "yes")
  end

  test "rejects unroutable answer values, ordered string comparisons, and out-of-range values" do
    {:ok, environment} = RoutePredecessors.derive_type_environment([judge()])

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.approved.choice", "gt", "m")

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.ref"}} =
             validate_ref(environment, "previous_output.urgency.legend", "eq", "x")

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.ref"}} =
             validate_ref(environment, "previous_output.approved.probabilities", "eq", "x")

    for {ref, value} <- [
          {"previous_output.approved.probabilities.yes", 1.2},
          {"previous_output.done.noul", -0.1},
          {"previous_output.urgency.score", 3}
        ] do
      assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
               validate_ref(environment, ref, "gte", value)
    end

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.urgency.score", "in", [1, 2, 5])
  end

  test "mixed route-envelope and structured predecessors may share task and execution rules" do
    {:ok, mixed} =
      RoutePredecessors.derive_type_environment([
        judge(),
        envelope(predecessor_schema(["yes"]))
      ])

    assert :ok = validate_ref(mixed, "task.level", "eq", "ticket")
    assert :ok = validate_ref(mixed, "execution.step_visit_count", "gt", 1)

    assert {:error, %{path: "$.rules[0].when.ref"}} =
             validate_ref(mixed, "previous_output.route.result", "eq", "yes")
  end

  defp judge do
    %{
      output_schema:
        StructuredInference.answers_schema(%{
          "approved" => %{
            "type" => "choice",
            "instructions" => "Are the requirements met?",
            "criteria" => %{"yes" => nil, "no" => nil}
          },
          "urgency" => %{
            "type" => "score",
            "instructions" => "How urgent is the follow-up?",
            "criteria" => ["low", "medium", "high"]
          },
          "done" => %{"type" => "noul", "instructions" => "Is the work finished?"}
        }),
      step_type: :structured_inference,
      transition_id: "judge"
    }
  end

  defp validate_ref(environment, ref, op, value) do
    {:ok, program} =
      RouteConfig.decode(%{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "check",
            "when" => %{"ref" => ref, "op" => op, "value" => value},
            "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
          }
        ],
        "default" => %{"transition" => %{"type" => "intra_workflow", "step_id" => @step_id}}
      })

    RoutePredecessors.validate(program, environment)
  end

  defp envelope(schema, id \\ "pred") do
    %{output_schema: schema, transition_id: id}
  end

  defp predecessor_schema(result_values) do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => result_values},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["note"],
              "properties" => %{"note" => %{"type" => "string"}}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
