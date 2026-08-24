defmodule Sacrum.Orchestrator.Routing.RouteModeTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.RouteMode

  @step_id "00000000-0000-0000-0000-000000000001"

  test "selects legacy routing only for a trimmed non-empty prompt" do
    assert {:ok, {:legacy, " Choose a destination "}} =
             RouteMode.routing_mode(%{
               prompt: " Choose a destination ",
               route_config: valid_config()
             })

    refute RouteMode.legacy_prompt?(nil)
    refute RouteMode.legacy_prompt?("")
    refute RouteMode.legacy_prompt?("   ")
  end

  test "selects deterministic routing for a blank prompt and valid configuration" do
    assert {:ok, {:deterministic, %{version: 1}}} =
             RouteMode.routing_mode(%{prompt: "   ", route_config: valid_config()})
  end

  test "requires configuration when no legacy prompt is present" do
    assert {:error, :route_not_configured} =
             RouteMode.routing_mode(%{prompt: nil, route_config: nil})
  end

  test "does not fall back to the prompt path after deterministic configuration errors" do
    assert {:error, %{code: :route_operand_type_mismatch, path: "$.rules[0].when.op"}} =
             RouteMode.routing_mode(%{prompt: "", route_config: ill_typed_config()})
  end

  defp valid_config do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "route",
          "when" => %{"ref" => "task.level", "op" => "eq", "value" => "task"},
          "transition" => %{"type" => "intra_workflow", "step_id" => @step_id}
        }
      ],
      "default" => %{"transition" => %{"type" => "intra_workflow", "step_id" => @step_id}}
    }
  end

  defp ill_typed_config do
    put_in(valid_config(), ["rules", Access.at(0), "when"], %{
      "ref" => "task.tags",
      "op" => "eq",
      "value" => "backend"
    })
  end
end
