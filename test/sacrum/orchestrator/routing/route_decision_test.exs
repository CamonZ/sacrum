defmodule Sacrum.Orchestrator.Routing.RouteDecisionTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.Routing.RouteDecision

  describe "log_route_decision/5" do
    test "logs a deterministic routing decision without crashing" do
      assert :ok =
               RouteDecision.log_route_decision(
                 "task_id",
                 "execution_id",
                 "dest_id",
                 "intra_workflow",
                 %{"source" => "route_config"}
               )
    end

    test "accepts a nil handoff" do
      assert :ok =
               RouteDecision.log_route_decision(
                 "task_id",
                 "execution_id",
                 "dest_id",
                 "inter_workflow",
                 nil
               )
    end
  end
end
