defmodule Sacrum.Orchestrator.Routing.RouteConfigTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.RouteConfig

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
          "transition" => %{"type" => "intra_workflow", "step_id" => @intra_step_id}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "inter_workflow", "workflow_id" => @inter_workflow_id}
      }
    }

    assert {:ok, decoded} = RouteConfig.decode(config)
    assert decoded.version == 1
    assert decoded.match_policy == :exactly_one
    assert [%{id: "all-predicates", transition: %{type: :intra_workflow}}] = decoded.rules
    assert decoded.default == %{type: :inter_workflow, workflow_id: @inter_workflow_id}
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
