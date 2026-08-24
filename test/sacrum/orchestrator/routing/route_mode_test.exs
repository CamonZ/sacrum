defmodule Sacrum.Orchestrator.Routing.RouteModeTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.RouteMode

  @step_id "00000000-0000-0000-0000-000000000001"

  test "selects legacy routing for every present prompt" do
    for prompt <- ["Choose a destination", "", "   "] do
      assert {:ok, {:legacy, ^prompt}} =
               RouteMode.routing_mode(%{
                 prompt: prompt,
                 route_config: valid_config()
               })
    end
  end

  test "selects deterministic routing for a null prompt and valid configuration" do
    assert {:ok, {:deterministic, %{version: 1}}} =
             RouteMode.routing_mode(%{prompt: nil, route_config: valid_config()})
  end

  test "requires configuration when no legacy prompt is present" do
    assert {:error, :route_not_configured} =
             RouteMode.routing_mode(%{prompt: nil, route_config: nil})
  end

  test "does not fall back to the prompt path after deterministic configuration errors" do
    assert {:error, %{code: :route_config_version_unsupported, path: "$.version"}} =
             RouteMode.routing_mode(%{prompt: nil, route_config: invalid_config()})
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

  defp invalid_config, do: %{valid_config() | "version" => 2}
end
