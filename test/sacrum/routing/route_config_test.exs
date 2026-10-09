defmodule Sacrum.Routing.RouteConfigTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.RouteConfig

  @intra_step_id "00000000-0000-0000-0000-000000000001"
  @inter_workflow_id "00000000-0000-0000-0000-000000000002"

  test "decodes every V1 expression and target node" do
    config = %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "all-predicates",
          "when" => %{
            "all" => [
              %{"ref" => "previous_output.route.result", "op" => "eq", "value" => "approved"},
              %{"ref" => "task.level", "op" => "in", "value" => ["epic", "ticket"]},
              %{"ref" => "task.tags", "op" => "contains", "value" => "backend"},
              %{
                "any" => [
                  %{
                    "ref" => "execution.step_visit_count",
                    "op" => "lte",
                    "value" => 3
                  },
                  %{
                    "not" => %{
                      "ref" => "previous_output.route.result",
                      "op" => "neq",
                      "value" => "approved"
                    }
                  }
                ]
              }
            ]
          },
          "transition" => %{"type" => "intra_workflow", "step_id" => @intra_step_id},
          "handoff" => %{"result" => "{{ previous_output.route.result }}"}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "inter_workflow", "workflow_id" => @inter_workflow_id},
        "handoff" => %{}
      }
    }

    assert {:ok, decoded} = RouteConfig.decode(config)
    assert decoded.version == 1
    assert decoded.match_policy == :exactly_one

    assert [%{id: "all-predicates", transition: %{type: :intra_workflow}, handoff: handoff}] =
             decoded.rules

    assert handoff == %{"result" => "{{ previous_output.route.result }}"}

    assert decoded.default == %{
             transition: %{type: :inter_workflow, workflow_id: @inter_workflow_id},
             handoff: nil,
             session: nil
           }
  end

  test "keeps code-like strings as inert predicate values" do
    config =
      config_with_when(%{
        "ref" => "previous_output.route.result",
        "op" => "eq",
        "value" => "System.cmd(\"rm\", [\"-rf\", \"/\"])"
      })

    assert {:ok, %{rules: [%{when: %{value: value}}]}} = RouteConfig.decode(config)
    assert value == "System.cmd(\"rm\", [\"-rf\", \"/\"])"
  end

  test "rejects unsupported versions with a stable error" do
    assert {:error, %{code: :route_config_version_unsupported, path: "$.version"}} =
             RouteConfig.decode(Map.put(base_config(), "version", 2))
  end

  test "rejects unknown keys, operators, and malformed boolean expressions" do
    assert {:error, %{path: "$.unexpected"}} =
             RouteConfig.decode(Map.put(base_config(), "unexpected", true))

    assert {:error, %{path: "$.rules[0].when.op"}} =
             RouteConfig.decode(
               config_with_when(%{"ref" => "task.level", "op" => "matches", "value" => "task"})
             )

    assert {:error, %{path: "$.rules[0].when.all"}} =
             RouteConfig.decode(config_with_when(%{"all" => []}))
  end

  test "rejects task.title at its submitted reference path" do
    assert {:error, %{path: "$.rules[0].when.ref"}} =
             RouteConfig.decode(
               config_with_when(%{"ref" => "task.title", "op" => "eq", "value" => "Title"})
             )
  end

  test "rejects invalid predicate pairs, operands, and open-domain routes without a default" do
    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.op"}} =
             RouteConfig.decode(
               config_with_when(%{"ref" => "task.tags", "op" => "eq", "value" => "backend"})
             )

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             RouteConfig.decode(
               config_with_when(%{
                 "ref" => "execution.step_visit_count",
                 "op" => "gte",
                 "value" => 0
               })
             )

    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.value"}} =
             RouteConfig.decode(
               config_with_when(%{"ref" => "task.tags", "op" => "contains_all", "value" => []})
             )

    assert {:error, %{code: :route_config_invalid, path: "$.default"}} =
             RouteConfig.decode(
               config_with_when(%{"ref" => "task.tags", "op" => "contains", "value" => "backend"})
             )
  end

  test "rejects duplicate rule identifiers and invalid targets" do
    duplicated =
      base_config()
      |> Map.put("rules", [base_rule(), base_rule()])

    assert {:error, %{path: "$.rules[1].id"}} = RouteConfig.decode(duplicated)

    invalid_target =
      base_config()
      |> put_in(["rules", Access.at(0), "transition", "step_id"], "not-a-uuid")

    assert {:error, %{path: "$.rules[0].transition.step_id"}} = RouteConfig.decode(invalid_target)
  end

  test "rejects non-object and malformed handoff templates at their submitted paths" do
    assert {:error, %{code: :route_handoff_template_invalid, path: "$.rules[0].handoff"}} =
             RouteConfig.decode(put_in(base_config(), ["rules", Access.at(0), "handoff"], []))

    assert {:error, %{code: :route_handoff_template_invalid, path: "$.rules[0].handoff.message"}} =
             RouteConfig.decode(
               put_in(
                 base_config(),
                 ["rules", Access.at(0), "handoff"],
                 %{"message" => "{{ task.level"}
               )
             )

    assert {:error, %{code: :route_handoff_template_invalid, path: "$.default.handoff.message"}} =
             RouteConfig.decode(
               Map.put(base_config(), "default", %{
                 "transition" => %{
                   "type" => "inter_workflow",
                   "workflow_id" => @inter_workflow_id
                 },
                 "handoff" => %{"message" => "{{ task.title }}"}
               })
             )
  end

  test "decodes session directives on rules and the default" do
    config =
      base_config()
      |> put_in(["rules", Access.at(0), "session"], %{"mode" => "resume"})
      |> Map.put("default", %{
        "transition" => %{"type" => "intra_workflow", "step_id" => @intra_step_id},
        "session" => %{"mode" => "fork", "step_id" => @inter_workflow_id}
      })

    assert {:ok, %{rules: [rule], default: default}} = RouteConfig.decode(config)
    assert rule.session == %{mode: :resume, step_id: nil}
    assert default.session == %{mode: :fork, step_id: @inter_workflow_id}

    new = put_in(base_config(), ["rules", Access.at(0), "session"], %{"mode" => "new"})
    assert {:ok, %{rules: [%{session: %{mode: :new, step_id: nil}}]}} = RouteConfig.decode(new)

    assert {:ok, %{rules: [%{session: nil}]}} = RouteConfig.decode(base_config())
  end

  test "rejects malformed session directives at their submitted paths" do
    for {session, path} <- [
          {"resume", "$.rules[0].session"},
          {%{}, "$.rules[0].session.mode"},
          {%{"mode" => "resume_or_new"}, "$.rules[0].session.mode"},
          {%{"mode" => "resume", "name" => "impl"}, "$.rules[0].session.name"},
          {%{"mode" => "resume", "step_id" => "not-a-uuid"}, "$.rules[0].session.step_id"},
          {%{"mode" => "new", "step_id" => @intra_step_id}, "$.rules[0].session.step_id"}
        ] do
      config = put_in(base_config(), ["rules", Access.at(0), "session"], session)

      assert {:error, %{code: :route_config_invalid, path: ^path}} = RouteConfig.decode(config),
             inspect(session)
    end

    default =
      Map.put(base_config(), "default", %{
        "transition" => %{"type" => "intra_workflow", "step_id" => @intra_step_id},
        "session" => %{"mode" => "branch"}
      })

    assert {:error, %{path: "$.default.session.mode"}} = RouteConfig.decode(default)
  end

  defp base_config do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [base_rule()]
    }
  end

  defp base_rule do
    %{
      "id" => "approved",
      "when" => %{"ref" => "previous_output.route.result", "op" => "eq", "value" => "approved"},
      "transition" => %{"type" => "intra_workflow", "step_id" => @intra_step_id}
    }
  end

  defp config_with_when(when_expression) do
    put_in(base_config(), ["rules", Access.at(0), "when"], when_expression)
  end
end
