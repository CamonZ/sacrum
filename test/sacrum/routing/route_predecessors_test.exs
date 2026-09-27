defmodule Sacrum.Routing.RoutePredecessorsTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep.Config.StructuredInference
  alias Sacrum.Routing.{RouteConfig, RoutePredecessors}

  @step_id "00000000-0000-0000-0000-000000000001"

  test "requires every predecessor to declare an object output schema" do
    assert {:error,
            %{
              code: :route_input_invalid,
              path: "$.predecessors[explain].output_schema",
              message: "is required for llm_inference steps that feed a route"
            }} =
             RoutePredecessors.derive_type_environment([
               %{output_schema: nil, step_type: :llm_inference, transition_id: "explain"}
             ])

    assert {:error, %{code: :route_input_invalid, path: "$.predecessors[0].output_schema"}} =
             RoutePredecessors.derive_type_environment([%{step_type: :human_input}])

    assert {:error, %{code: :route_input_invalid, path: "$.predecessors[pred].output_schema"}} =
             RoutePredecessors.derive_type_environment([envelope(%{"type" => "string"})])
  end

  test "route.result is an ordinary path whose enum is the union across predecessors" do
    {:ok, environment} =
      RoutePredecessors.derive_type_environment([
        envelope(predecessor_schema(["approved"]), "approved"),
        envelope(predecessor_schema(["rejected", "retry"]), "rejected")
      ])

    assert :ok = validate_ref(environment, "previous_output.route.result", "eq", "approved")
    assert :ok = validate_ref(environment, "previous_output.route.result", "in", ["retry"])

    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.route.result", "eq", "maybe")

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.route.result", "eq", 1)

    {:ok, program} =
      RouteConfig.decode(config([rule("previous_output.route.result", "approved")]))

    assert %{"previous_output.route.result" => values} =
             RoutePredecessors.closed_domains(program, environment)

    assert Enum.sort(values) == ["approved", "rejected", "retry"]
  end

  test "routes on a declared verdict and hands off a declared explanation" do
    {:ok, environment} = RoutePredecessors.derive_type_environment([explain()])

    assert :ok =
             validate_config(
               config([
                 rule("previous_output.verdict", "needs_changes", %{
                   "how" => "{{ previous_output.explanation }}",
                   "level" => "{{ task.level }}"
                 }),
                 rule("previous_output.verdict", "ready")
               ]),
               environment
             )

    {:ok, program} = RouteConfig.decode(config([rule("previous_output.verdict", "ready")]))

    assert RoutePredecessors.closed_domains(program, environment) == %{
             "previous_output.verdict" => ["needs_changes", "ready"]
           }
  end

  test "rejects undeclared rule references and values outside the declared enum" do
    {:ok, environment} = RoutePredecessors.derive_type_environment([explain()])

    assert {:error,
            %{
              code: :route_config_invalid,
              path: "$.rules[0].when.value",
              message: ~s("approved" is not declared)
            }} = validate_ref(environment, "previous_output.verdict", "eq", "approved")

    assert {:error,
            %{
              code: :route_config_invalid,
              path: "$.rules[0].when.ref",
              message: ~s("status" is not declared)
            }} = validate_ref(environment, "previous_output.status", "eq", "ready")

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             validate_ref(environment, "previous_output.verdict", "gt", "ready")
  end

  test "rejects undeclared, non-optional, and embedded container handoff references" do
    {:ok, environment} = RoutePredecessors.derive_type_environment([explain()])

    assert {:error,
            %{
              code: :route_handoff_template_invalid,
              path: "$.rules[0].handoff.why",
              message: message
            }} = validate_handoff(environment, %{"why" => "{{ previous_output.reason }}"})

    assert message =~ ~s("reason" is not declared)

    assert {:error, %{code: :route_handoff_template_invalid, path: "$.default.handoff.notes"}} =
             validate_config(
               config([rule("previous_output.verdict", "ready")], %{
                 "notes" => "{{ previous_output.notes }}"
               }),
               environment
             )

    assert {:error,
            %{
              code: :route_handoff_template_invalid,
              path: "$.rules[0].handoff.list[0]",
              message: message
            }} =
             validate_handoff(environment, %{"list" => ["{{ previous_output.notes.author }}"]})

    assert message =~ ~s("notes" is not required; mark the reference optional with ?)

    assert :ok =
             validate_handoff(environment, %{
               "notes" => "{{ previous_output.notes? }}",
               "author" => "by {{ previous_output.notes.author? }}"
             })

    assert {:error,
            %{
              code: :route_handoff_template_invalid,
              path: "$.rules[0].handoff.summary",
              message: message
            }} =
             validate_handoff(environment, %{"summary" => "See {{ previous_output.notes? }}"})

    assert message =~ "must occupy the whole string"
  end

  test "handoff references must be declared by every predecessor" do
    {:ok, environment} =
      RoutePredecessors.derive_type_environment([
        explain(),
        envelope(predecessor_schema(["ready"]))
      ])

    validate = fn handoff ->
      validate_config(config([rule("task.level", "ticket", handoff)]), environment)
    end

    assert {:error, %{code: :route_handoff_template_invalid, path: "$.rules[0].handoff.how"}} =
             validate.(%{"how" => "{{ previous_output.explanation }}"})

    assert :ok = validate.(%{"level" => "{{ task.level }}"})
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

  defp explain do
    %{
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["needs_changes", "ready"]},
          "explanation" => %{"type" => "string"},
          "notes" => %{
            "type" => "object",
            "properties" => %{"author" => %{"type" => "string"}},
            "required" => ["author"]
          }
        },
        "required" => ["verdict", "explanation"],
        "additionalProperties" => false
      },
      step_type: :llm_inference,
      transition_id: "explain"
    }
  end

  defp validate_handoff(environment, handoff) do
    validate_config(
      config([
        rule("previous_output.verdict", "needs_changes", handoff),
        rule("previous_output.verdict", "ready")
      ]),
      environment
    )
  end

  defp validate_config(config, environment) do
    {:ok, program} = RouteConfig.decode(config)
    RoutePredecessors.validate(program, environment)
  end

  defp config(rules, default_handoff \\ nil) do
    default =
      %{"transition" => %{"type" => "intra_workflow", "step_id" => @step_id}}
      |> then(&if default_handoff, do: Map.put(&1, "handoff", default_handoff), else: &1)

    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => rules,
      "default" => default
    }
  end

  defp rule(ref, value, handoff \\ nil) do
    rule = %{
      "id" => value,
      "when" => %{"ref" => ref, "op" => "eq", "value" => value},
      "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
    }

    if handoff, do: Map.put(rule, "handoff", handoff), else: rule
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
