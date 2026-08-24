defmodule Sacrum.Orchestrator.Routing.RouteContextTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.{RouteConfig, RouteContext}

  @step_id "00000000-0000-0000-0000-000000000001"

  test "builds only the four whitelisted route values" do
    previous_output = %{"route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}}
    task = %{"level" => "ticket", "tags" => ["backend", "urgent"]}

    assert {:ok, context} = RouteContext.build(previous_output, task, 2)
    assert {:ok, "approved"} = RouteContext.fetch(context, :previous_output_route_result)
    assert {:ok, "ticket"} = RouteContext.fetch(context, :task_level)
    assert {:ok, ["backend", "urgent"]} = RouteContext.fetch(context, :task_tags)
    assert {:ok, 2} = RouteContext.fetch(context, :execution_step_visit_count)

    assert {:error, %{code: :route_reference_unknown}} = RouteContext.fetch(context, :task_title)
  end

  test "rejects malformed predecessor output and invalid task values" do
    assert {:error, %{code: :route_input_invalid, path: "$.previous_output.route"}} =
             RouteContext.build(%{"route" => %{}}, %{"level" => "task", "tags" => []}, 1)

    assert {:error, %{path: "$.task.level"}} =
             RouteContext.build(valid_output(), %{"level" => "high", "tags" => []}, 1)

    assert {:error, %{path: "$.task.tags"}} =
             RouteContext.build(valid_output(), %{"level" => "task", "tags" => [1]}, 1)

    assert {:error, %{path: "$.execution.step_visit_count"}} =
             RouteContext.build(valid_output(), %{"level" => "task", "tags" => []}, 0)

    assert {:error, %{path: "$.task"}} =
             RouteContext.build(valid_output(), %{level: "task", tags: []}, 1)
  end

  test "derives the result enum union from valid predecessor envelopes" do
    approved_schema = predecessor_schema(["approved"])
    rejected_schema = predecessor_schema(["rejected", "retry"])

    assert {:ok, %{result_values: result_values}} =
             RouteContext.derive_type_environment([approved_schema, rejected_schema])

    assert result_values == MapSet.new(["approved", "rejected", "retry"])
  end

  test "rejects predecessor schemas without a result enum or strict handoff" do
    missing_enum =
      put_in(predecessor_schema(["approved"]), ["properties", "route", "properties", "result"], %{
        "type" => "string"
      })

    assert {:error, %{code: :route_input_invalid, path: "$.properties.route.properties.result"}} =
             RouteContext.validate_predecessor_schema(missing_enum)

    loose_handoff =
      put_in(
        predecessor_schema(["approved"]),
        ["properties", "route", "properties", "handoff"],
        %{"type" => "object", "properties" => %{}, "required" => []}
      )

    assert {:error, %{code: :route_input_invalid, path: "$.properties.route.properties.handoff"}} =
             RouteContext.validate_predecessor_schema(loose_handoff)
  end

  test "accepts enum, tag, and visit predicates with nested boolean composition" do
    {:ok, program} =
      RouteConfig.decode(%{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "route",
            "when" => %{
              "all" => [
                %{"ref" => "previous_output.route.result", "op" => "in", "value" => ["approved"]},
                %{"ref" => "task.level", "op" => "neq", "value" => "epic"},
                %{"ref" => "task.tags", "op" => "contains_all", "value" => ["backend"]},
                %{
                  "not" => %{
                    "ref" => "execution.step_visit_count",
                    "op" => "gt",
                    "value" => 3
                  }
                }
              ]
            },
            "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
          }
        ],
        "default" => %{"transition" => %{"type" => "intra_workflow", "step_id" => @step_id}}
      })

    assert :ok = RouteContext.validate(program)
    assert :ok = RouteContext.validate(program, ["approved", "rejected"])
  end

  test "rejects unknown references, incompatible values, and missing defaults" do
    assert {:error, %{code: :route_reference_unknown, path: "$.rules[0].when.ref"}} =
             RouteContext.validate(predicate_program(:unknown, :eq, "value"), ["approved"])

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.op"}} =
             RouteContext.validate(predicate_program(:task_tags, :eq, "backend"), ["approved"])

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             RouteContext.validate(predicate_program(:execution_step_visit_count, :gte, "2"), [
               "approved"
             ])

    assert {:error, %{code: :route_config_invalid, path: "$.default"}} =
             RouteContext.validate(predicate_program(:task_tags, :contains, "backend", nil), [
               "approved"
             ])
  end

  test "rejects predecessor result values outside its declared enum" do
    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             RouteContext.validate(
               predicate_program(:previous_output_route_result, :eq, "maybe"),
               ["approved"]
             )
  end

  defp valid_output do
    %{"route" => %{"result" => "approved", "handoff" => %{"note" => "ready"}}}
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

  defp predicate_program(
         reference,
         operator,
         value,
         default \\ %{type: :intra_workflow, step_id: @step_id}
       ) do
    %{
      rules: [
        %{
          id: "predicate",
          when: %{kind: :predicate, ref: reference, operator: operator, value: value},
          transition: %{type: :intra_workflow, step_id: @step_id}
        }
      ],
      default: default
    }
  end
end
