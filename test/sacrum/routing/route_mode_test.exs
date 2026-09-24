defmodule Sacrum.Routing.RouteModeTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.RouteMode

  @step_id "00000000-0000-0000-0000-000000000001"

  test "selects deterministic routing when the configuration compiles" do
    assert {:ok, {:deterministic, %{version: 1}}} =
             RouteMode.routing_mode(route(valid_config()))
  end

  test "requires route configuration" do
    assert {:error, :route_config_required} =
             RouteMode.routing_mode(route(nil))
  end

  test "fails closed when a present configuration cannot compile" do
    assert {:error, %{code: :route_config_version_unsupported, path: "$.version"}} =
             RouteMode.routing_mode(route(invalid_config()))
  end

  test "does not invent a prompt after deterministic configuration errors" do
    assert {:error, %{code: :route_config_version_unsupported, path: "$.version"}} =
             RouteMode.routing_mode(route(invalid_config()))
  end

  defp route(route_config),
    do: %WorkflowStep{
      step_type: :route,
      config: %Config.Route{route_config: route_config}
    }

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
