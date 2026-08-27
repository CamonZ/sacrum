defmodule Sacrum.Routing.RouteModeTest do
  use ExUnit.Case, async: true

  alias Sacrum.Routing.RouteMode

  @step_id "00000000-0000-0000-0000-000000000001"

  test "selects deterministic routing when the configuration compiles" do
    for prompt <- ["Choose a destination", nil, "", "   "] do
      assert {:ok, {:deterministic, %{version: 1}}} =
               RouteMode.routing_mode(%{
                 prompt: prompt,
                 route_config: valid_config()
               })
    end
  end

  test "selects legacy routing when no configuration is present" do
    assert {:ok, {:legacy, "Choose a destination"}} =
             RouteMode.routing_mode(%{
               prompt: "Choose a destination",
               route_config: nil
             })
  end

  test "requires configuration when no compiled route or prompt is present" do
    assert {:error, :route_not_configured} =
             RouteMode.routing_mode(%{prompt: nil, route_config: nil})
  end

  test "does not fall back to the prompt when present configuration cannot compile" do
    assert {:error, %{code: :route_config_version_unsupported, path: "$.version"}} =
             RouteMode.routing_mode(%{
               prompt: "Choose a destination",
               route_config: invalid_config()
             })
  end

  test "does not invent a prompt after deterministic configuration errors" do
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
