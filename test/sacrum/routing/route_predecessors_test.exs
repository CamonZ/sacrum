defmodule Sacrum.Routing.RoutePredecessorsTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.{RouteConfig, RoutePredecessors}

  @step_id "00000000-0000-0000-0000-000000000001"

  test "derives the result enum union from valid predecessor envelopes" do
    approved_schema = predecessor_schema(["approved"])
    rejected_schema = predecessor_schema(["rejected", "retry"])

    assert {:ok, %{result_values: result_values}} =
             RoutePredecessors.derive_type_environment([approved_schema, rejected_schema])

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
      RoutePredecessors.derive_type_environment([predecessor_schema(["approved"])])

    assert {:error, %{code: :route_config_invalid, path: "$.rules[0].when.value"}} =
             RoutePredecessors.validate(program, type_environment)
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
